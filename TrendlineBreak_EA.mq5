//+------------------------------------------------------------------+
//|                                        TrendlineBreak_EA.mq5      |
//|  Trendline Break EA - stop & reverse (multi-instrument)           |
//|                                                                    |
//|  Own implementation of the classic pivot-based dynamic trendline  |
//|  break concept (same idea as oscillators that plot a green dot on |
//|  a bullish trendline break and a red dot on a bearish break).     |
//|  This is NOT a port of any third-party proprietary indicator -    |
//|  it is written independently so it can run fully automated. Not   |
//|  tied to any single symbol - originally built for XAUUSD, also    |
//|  validated on indices such as US30.                               |
//|                                                                    |
//|  Logic (v2 - "reaction at the line"):                             |
//|   - Detect confirmed pivot highs/lows (PivotLookback bars each     |
//|     side) and project a resistance line through the last 2 pivot  |
//|     highs and a support line through the last 2 pivot lows.       |
//|   - Every time price reacts to one of these lines there are two   |
//|     possible outcomes, and the EA trades whichever one actually   |
//|     happens:                                                      |
//|       1) BREAKOUT (continuation): a closed bar clears the line    |
//|          by the confirmation buffer -> trade in that direction.   |
//|       2) BOUNCE (reversal): price touches the line (ATR-based     |
//|          tolerance) without clearing it, confirmed by a candle    |
//|          reversal pattern (engulfing / pin bar) -> trade in the   |
//|          opposite direction.                                      |
//|   - Whichever fires first "reacts" that line so it only fires     |
//|     once per pivot projection.                                    |
//|   - Every entry carries an ATR-based SL and an R:R-based TP, so   |
//|     the position also closes automatically when the profit        |
//|     target is reached, not only on the opposite signal.           |
//|   - An automatic R-multiple visual panel (entry / SL / 1R..NR      |
//|     levels + profit-loss shading) is drawn on every entry.        |
//|                                                                    |
//|  Risk management:                                                 |
//|   - Position size targets a fixed dollar risk per trade (default  |
//|     $50), with a hard lot-size cap as a second safety net.        |
//|   - A circuit breaker pauses new entries after N consecutive      |
//|     stop-loss hits (default 2), resuming automatically the next   |
//|     calendar day.                                                 |
//|   - Optional push notifications on every open/close (MetaQuotes   |
//|     ID must be linked in Tools > Options > Notifications).        |
//|                                                                    |
//|  Educational / research template. Backtest and forward-test on    |
//|  demo before using with real capital. No strategy is guaranteed   |
//|  to be profitable.                                                |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Trendline Break Stop & Reverse"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_ENTRY_MODE
  {
   ENTRY_BREAKOUT_ONLY,
   ENTRY_BOUNCE_ONLY,
   ENTRY_BOTH
  };

//====================== INPUTS ======================================
input group "=== General ==="
input ulong  MagicNumber            = 20260912;
input string TradeComment           = "TLBreak";
input double MaxSpreadPoints        = 500;

input group "=== Trendline ==="
input int    PivotLookback          = 5;      // bars each side to confirm a pivot

input group "=== Entry Logic ==="
input ENUM_ENTRY_MODE EntryMode        = ENTRY_BOTH;  // Breakout=continuation, Bounce=reversal, Both=react to whichever happens
input double           BreakoutBufferPoints = 200;    // extra buffer beyond the line, in points, to confirm a breakout
input double           TouchATRMultiplier   = 0.35;   // how close (x ATR) price must get to the line to count as a touch
input bool             UseEngulfingPattern  = true;   // confirm bounce with engulfing pattern
input bool             UsePinBarPattern     = true;   // confirm bounce with pin bar (hammer / shooting star)

input group "=== Risk / Stop Loss / Take Profit ==="
input double SL_ATR_Multiplier      = 1.5;
input double RR_Multiplier          = 3.0;
input int    ATR_Period             = 14;

input group "=== Position Sizing (your account) ==="
input bool   UseFixedRiskUSD        = true;   // true = risk a fixed $ amount per trade; false = risk % of balance
input double FixedRiskUSD           = 50.0;   // $ risked per trade when UseFixedRiskUSD is on
input double RiskPercent            = 1.0;    // used only when UseFixedRiskUSD is off
input double MaxLotSize             = 5.0;    // hard cap - never trade more than this, whatever the risk calc says

input group "=== Loss Circuit Breaker ==="
input int    MaxConsecutiveLosses   = 2;      // pause new entries after this many stop-loss hits in a row
                                               // (auto-resumes at the start of the next calendar day)

input group "=== Account Protection (prop firm limits) ==="
input double DailyLossLimitPercent  = 3.5;    // % of the day's starting balance - stop trading for the day if hit
                                               // (set below your firm's actual daily drawdown limit, for buffer)
input double MaxDrawdownPercent     = 7.0;    // % below the highest equity seen - halts the EA entirely if hit
                                               // (set below your firm's actual max drawdown limit, for buffer)
input bool   CloseOnProtectionTrigger = true; // immediately close any open position when a limit is hit,
                                               // instead of waiting for its own SL

input group "=== Notifications ==="
input bool   EnablePushNotifications = true;  // requires a MetaQuotes ID linked in Tools > Options > Notifications

input group "=== Chart Visuals ==="
input bool   DrawTrendlines         = true;
input bool   ShowRPanel             = true;   // draw automatic R-multiple panel on entry
input int    MaxRLevels             = 5;      // max R levels to draw (1R..NR)
input int    PanelBars              = 20;     // panel width, in bars

//====================== STATE ========================================
double ph1 = 0, ph2 = 0;
datetime phTime1 = 0, phTime2 = 0;
double pl1 = 0, pl2 = 0;
datetime plTime1 = 0, plTime2 = 0;

bool resReacted = false;
bool supReacted = false;

int atrHandle = INVALID_HANDLE;

int      consecutiveLosses = 0;
datetime lastResetDay      = 0;

double   dayStartBalance       = 0;
double   peakEquity            = 0;
bool     dailyProtectionActive = false;
bool     accountBlownProtection = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
     {
      Alert("Failed to create ATR handle.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   if(CopyBuffer(atrHandle, 0, 1, 1, buf) != 1) return(0.0);
   return(buf[0]);
  }

bool SpreadOK()
  {
   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   return(spreadPts <= MaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| Daily rollover - resets the consecutive-loss counter and the     |
//| day's starting balance (used by the daily loss limit) once per   |
//| calendar day. Does NOT reset the max-drawdown protection, which  |
//| is meant to be permanent for the life of this EA run.            |
//+------------------------------------------------------------------+
void MaybeRolloverDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);
   if(today != lastResetDay)
     {
      consecutiveLosses      = 0;
      dayStartBalance        = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProtectionActive  = false;
      lastResetDay           = today;
     }
  }

//+------------------------------------------------------------------+
//| Account protection - mirrors the prop firm's daily and max        |
//| drawdown limits, with a safety buffer, so this EA never has to    |
//| rely on the firm's own risk desk closing the account for us.      |
//| Max-drawdown is measured from the highest equity seen (trailing), |
//| which is the more conservative reading whether the firm's own    |
//| rule is trailing or static from the initial balance.              |
//+------------------------------------------------------------------+
void EmergencyStop(string reasonLabel)
  {
   if(CloseOnProtectionTrigger && PositionSelect(_Symbol))
      trade.PositionClose(_Symbol);

   string msg = "PROTECCION DE CUENTA: limite de " + reasonLabel + " alcanzado. Trading detenido.";
   Print(msg);
   if(EnablePushNotifications) SendNotification(msg);
  }

void CheckAccountProtection()
  {
   MaybeRolloverDay();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > peakEquity) peakEquity = equity;

   double dailyLossPct = (dayStartBalance > 0) ? (dayStartBalance - equity) / dayStartBalance * 100.0 : 0.0;
   double drawdownPct  = (peakEquity > 0)      ? (peakEquity - equity) / peakEquity * 100.0           : 0.0;

   if(!accountBlownProtection && drawdownPct >= MaxDrawdownPercent)
     {
      accountBlownProtection = true;
      EmergencyStop("DRAWDOWN MAXIMO (" + DoubleToString(MaxDrawdownPercent, 1) + "%)");
     }

   if(!dailyProtectionActive && dailyLossPct >= DailyLossLimitPercent)
     {
      dailyProtectionActive = true;
      EmergencyStop("PERDIDA DIARIA (" + DoubleToString(DailyLossLimitPercent, 1) + "%)");
     }
  }

bool TradingPaused()
  {
   MaybeRolloverDay();
   if(accountBlownProtection) return(true);
   if(dailyProtectionActive)  return(true);
   return(consecutiveLosses >= MaxConsecutiveLosses);
  }

//+------------------------------------------------------------------+
double CalcLotSize(double slDistancePrice)
  {
   double riskMoney = UseFixedRiskUSD ? FixedRiskUSD : (AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0);

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || slDistancePrice <= 0) return(0.0);

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0) return(0.0);

   double lots = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;

   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathMin(lots, MaxLotSize);   // hard cap for this account, regardless of the risk calc above
   return(lots);
  }

//+------------------------------------------------------------------+
//| Pivot detection - checks the bar that is PivotLookback bars back |
//| from the last closed bar (shift 1), i.e. cShift = PivotLookback+1|
//+------------------------------------------------------------------+
bool IsPivotHigh(double &pivotPrice, datetime &pivotTime)
  {
   int cShift = PivotLookback + 1;
   double candidate = iHigh(_Symbol, PERIOD_CURRENT, cShift);
   for(int i = 1; i <= PivotLookback; i++)
     {
      if(iHigh(_Symbol, PERIOD_CURRENT, cShift - i) > candidate) return(false);
      if(iHigh(_Symbol, PERIOD_CURRENT, cShift + i) > candidate) return(false);
     }
   pivotPrice = candidate;
   pivotTime  = iTime(_Symbol, PERIOD_CURRENT, cShift);
   return(true);
  }

bool IsPivotLow(double &pivotPrice, datetime &pivotTime)
  {
   int cShift = PivotLookback + 1;
   double candidate = iLow(_Symbol, PERIOD_CURRENT, cShift);
   for(int i = 1; i <= PivotLookback; i++)
     {
      if(iLow(_Symbol, PERIOD_CURRENT, cShift - i) < candidate) return(false);
      if(iLow(_Symbol, PERIOD_CURRENT, cShift + i) < candidate) return(false);
     }
   pivotPrice = candidate;
   pivotTime  = iTime(_Symbol, PERIOD_CURRENT, cShift);
   return(true);
  }

//+------------------------------------------------------------------+
double LineValueAt(double basePrice, double slope, datetime baseTime, datetime t)
  {
   return(basePrice + slope * (double)(t - baseTime));
  }

//+------------------------------------------------------------------+
void DrawLine(string name, datetime t1, double p1, datetime t2, double p2, color clr)
  {
   if(!DrawTrendlines) return;
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
  }

//+------------------------------------------------------------------+
//| Candlestick reversal patterns, evaluated on the last closed bar   |
//| (shift 1) against the bar before it (shift 2)                    |
//+------------------------------------------------------------------+
bool IsBullishEngulfing()
  {
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1), close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2), close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   return(close2 < open2 && close1 > open1 && close1 >= open2 && open1 <= close2);
  }

bool IsBearishEngulfing()
  {
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1), close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2), close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   return(close2 > open2 && close1 < open1 && open1 >= close2 && close1 <= open2);
  }

bool IsHammer()
  {
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1), close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1), low1   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double body = MathAbs(close1 - open1);
   double upperWick = high1 - MathMax(close1, open1);
   double lowerWick = MathMin(close1, open1) - low1;
   return(body > 0 && lowerWick >= body * 2.0 && upperWick <= body * 0.6);
  }

bool IsShootingStar()
  {
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1), close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1), low1   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double body = MathAbs(close1 - open1);
   double upperWick = high1 - MathMax(close1, open1);
   double lowerWick = MathMin(close1, open1) - low1;
   return(body > 0 && upperWick >= body * 2.0 && lowerWick <= body * 0.6);
  }

bool BullishPatternConfirmed()
  {
   return((UseEngulfingPattern && IsBullishEngulfing()) || (UsePinBarPattern && IsHammer()));
  }

bool BearishPatternConfirmed()
  {
   return((UseEngulfingPattern && IsBearishEngulfing()) || (UsePinBarPattern && IsShootingStar()));
  }

//+------------------------------------------------------------------+
//| Touch detection (last closed bar vs. the line's current value)   |
//+------------------------------------------------------------------+
bool TouchingSupport(double supAtCurr, double touchTol)
  {
   double low1 = iLow(_Symbol, PERIOD_CURRENT, 1), close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   return(low1 <= supAtCurr + touchTol && close1 > supAtCurr - touchTol);
  }

bool TouchingResistance(double resAtCurr, double touchTol)
  {
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1), close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   return(high1 >= resAtCurr - touchTol && close1 < resAtCurr + touchTol);
  }

//+------------------------------------------------------------------+
//| Chart visuals: signal arrow, trade label and R-multiple panel    |
//+------------------------------------------------------------------+
void DrawSignalMarker(bool isLong, datetime t, double price)
  {
   string name = "TLBreak_Sig_" + TimeToString(t, TIME_DATE|TIME_MINUTES) + (isLong ? "_L" : "_S");
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, isLong ? 233 : 234);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isLong ? clrLime : clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void DrawTradeLabel(bool isLong, datetime t, double entry, double sl, double tp, string reasonText)
  {
   string name = "TLBreak_Lbl_" + TimeToString(t, TIME_DATE|TIME_SECONDS);
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   double anchorPrice = isLong ? MathMin(sl, entry) - MathAbs(entry - sl) * 0.3
                                : MathMax(sl, entry) + MathAbs(entry - sl) * 0.3;
   string txt = (isLong ? "BUY " : "SELL ") + reasonText +
                "\nEntry " + DoubleToString(entry, _Digits) +
                "\nSL " + DoubleToString(sl, _Digits) + "  TP " + DoubleToString(tp, _Digits) +
                "\nR:R 1:" + DoubleToString(RR_Multiplier, 1);
   ObjectCreate(0, name, OBJ_TEXT, 0, t, anchorPrice);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isLong ? clrLime : clrRed);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void ClearRPanel()
  {
   ObjectDelete(0, "TLBreak_R0");
   ObjectDelete(0, "TLBreak_RSL");
   ObjectDelete(0, "TLBreak_ProfitBox");
   ObjectDelete(0, "TLBreak_LossBox");
   int clearUpTo = MathMax(MaxRLevels, 10);
   for(int i = 1; i <= clearUpTo; i++)
     {
      ObjectDelete(0, "TLBreak_R" + IntegerToString(i));
      ObjectDelete(0, "TLBreak_R" + IntegerToString(i) + "_lbl");
     }
  }

void DrawRPanel(bool isLong, datetime t, double entry, double sl, double slDist)
  {
   if(!ShowRPanel) return;
   ClearRPanel();
   datetime t2 = t + PeriodSeconds() * PanelBars;

   ObjectCreate(0, "TLBreak_R0", OBJ_TREND, 0, t, entry, t2, entry);
   ObjectSetInteger(0, "TLBreak_R0", OBJPROP_COLOR, clrGray);
   ObjectSetInteger(0, "TLBreak_R0", OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, "TLBreak_R0", OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, "TLBreak_R0", OBJPROP_SELECTABLE, false);

   ObjectCreate(0, "TLBreak_RSL", OBJ_TREND, 0, t, sl, t2, sl);
   ObjectSetInteger(0, "TLBreak_RSL", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, "TLBreak_RSL", OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, "TLBreak_RSL", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, "TLBreak_RSL", OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, "TLBreak_RSL", OBJPROP_SELECTABLE, false);

   double tpFinal = isLong ? entry + slDist * RR_Multiplier : entry - slDist * RR_Multiplier;
   ObjectCreate(0, "TLBreak_ProfitBox", OBJ_RECTANGLE, 0, t, entry, t2, tpFinal);
   ObjectSetInteger(0, "TLBreak_ProfitBox", OBJPROP_COLOR, clrGreen);
   ObjectSetInteger(0, "TLBreak_ProfitBox", OBJPROP_FILL, true);
   ObjectSetInteger(0, "TLBreak_ProfitBox", OBJPROP_BACK, true);
   ObjectSetInteger(0, "TLBreak_ProfitBox", OBJPROP_SELECTABLE, false);

   ObjectCreate(0, "TLBreak_LossBox", OBJ_RECTANGLE, 0, t, entry, t2, sl);
   ObjectSetInteger(0, "TLBreak_LossBox", OBJPROP_COLOR, clrCrimson);
   ObjectSetInteger(0, "TLBreak_LossBox", OBJPROP_FILL, true);
   ObjectSetInteger(0, "TLBreak_LossBox", OBJPROP_BACK, true);
   ObjectSetInteger(0, "TLBreak_LossBox", OBJPROP_SELECTABLE, false);

   for(int i = 1; i <= MaxRLevels; i++)
     {
      double lvl = isLong ? entry + slDist * i : entry - slDist * i;
      bool isTarget = i <= (int)MathRound(RR_Multiplier);
      string name = "TLBreak_R" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_TREND, 0, t, lvl, t2, lvl);
      ObjectSetInteger(0, name, OBJPROP_COLOR, isTarget ? clrLime : clrTeal);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

      string lblName = name + "_lbl";
      ObjectCreate(0, lblName, OBJ_TEXT, 0, t2, lvl);
      ObjectSetString(0, lblName, OBJPROP_TEXT, IntegerToString(i) + "  " + DoubleToString(lvl, _Digits));
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, isTarget ? clrLime : clrTeal);
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
void ExecuteEntry(bool isLong, string reasonText)
  {
   if(TradingPaused())
      return; // circuit breaker: too many consecutive stop-losses today

   // Close opposite position first (stop & reverse)
   if(PositionSelect(_Symbol))
     {
      long type = PositionGetInteger(POSITION_TYPE);
      bool isOpposite = (isLong && type == POSITION_TYPE_SELL) || (!isLong && type == POSITION_TYPE_BUY);
      if(isOpposite)
         trade.PositionClose(_Symbol);
      else
         return; // already in the same direction, do nothing
     }

   if(!SpreadOK()) return;

   double atr = GetATR();
   if(atr <= 0) return;

   double slDist = atr * SL_ATR_Multiplier;
   double price  = isLong ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl     = isLong ? price - slDist : price + slDist;
   double tp     = isLong ? price + slDist * RR_Multiplier : price - slDist * RR_Multiplier;

   double lots = CalcLotSize(slDist);
   if(lots <= 0) return;

   string cmt = TradeComment + " " + reasonText;
   bool ok = isLong ? trade.Buy(lots, _Symbol, price, sl, tp, cmt)
                    : trade.Sell(lots, _Symbol, price, sl, tp, cmt);
   if(!ok) return;

   datetime now = TimeCurrent();
   DrawSignalMarker(isLong, now, isLong ? SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr * 0.3
                                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr * 0.3);
   DrawTradeLabel(isLong, now, price, sl, tp, reasonText);
   DrawRPanel(isLong, now, price, sl, slDist);

   if(EnablePushNotifications)
     {
      string msg = _Symbol + " " + (isLong ? "BUY" : "SELL") + " " + DoubleToString(lots, 2) +
                   " lotes @ " + DoubleToString(price, _Digits) +
                   " | SL " + DoubleToString(sl, _Digits) + " TP " + DoubleToString(tp, _Digits) +
                   " | " + reasonText + " | riesgo $" + DoubleToString(UseFixedRiskUSD ? FixedRiskUSD : 0, 2);
      SendNotification(msg);
     }
  }

//+------------------------------------------------------------------+
//| Fires on every deal (open or close). Used here to track the loss |
//| circuit breaker and to push a notification when a position       |
//| closes - regardless of whether it closed by SL, TP, or manually  |
//| (including our own stop & reverse).                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest      &request,
                        const MqlTradeResult       &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)MagicNumber) return;

   long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY) return; // only care about closing deals

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   long reasonCode = HistoryDealGetInteger(trans.deal, DEAL_REASON);

   MaybeRolloverDay();

   bool wasSL = (reasonCode == DEAL_REASON_SL);
   bool wasTP = (reasonCode == DEAL_REASON_TP);

   if(wasSL)
      consecutiveLosses++;
   else if(profit > 0)
      consecutiveLosses = 0;

   if(EnablePushNotifications)
     {
      string reasonStr = wasSL ? "STOP LOSS" : wasTP ? "TAKE PROFIT" : "Manual/Reversa";
      string msg = _Symbol + " CERRADA (" + reasonStr + ") P/L: " + DoubleToString(profit, 2) +
                   " | SL seguidos: " + IntegerToString(consecutiveLosses) + "/" + IntegerToString(MaxConsecutiveLosses);
      SendNotification(msg);
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Runs on every tick (not just new bars) so an emergency close can react
   // immediately if the account gets close to the prop firm's limits.
   CheckAccountProtection();

   static datetime lastBarTime = 0;
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (barTime != lastBarTime);
   if(!isNewBar) return;
   lastBarTime = barTime;

   string status = accountBlownProtection ? "DETENIDO - drawdown maximo alcanzado (reinicia el EA solo tras confirmar con FTUK)"
                 : dailyProtectionActive  ? "PAUSADO HOY - limite de perdida diaria alcanzado (se reanuda mañana)"
                 : (consecutiveLosses >= MaxConsecutiveLosses) ? "PAUSADO - " + IntegerToString(consecutiveLosses) + " SL seguidos (se reanuda mañana)"
                 : "activo (" + IntegerToString(consecutiveLosses) + "/" + IntegerToString(MaxConsecutiveLosses) + " SL seguidos)";
   Comment("TrendlineBreak EA - " + status);

   // --- Update pivots (checked once per new closed bar) ---
   double newPh, newPl;
   datetime newPhTime, newPlTime;

   if(IsPivotHigh(newPh, newPhTime) && newPhTime != phTime1)
     {
      ph2 = ph1; phTime2 = phTime1;
      ph1 = newPh; phTime1 = newPhTime;
      resReacted = false;
     }

   if(IsPivotLow(newPl, newPlTime) && newPlTime != plTime1)
     {
      pl2 = pl1; plTime2 = plTime1;
      pl1 = newPl; plTime1 = newPlTime;
      supReacted = false;
     }

   // --- Compute trendline projections and check for a reaction on the last two closed bars ---
   bool haveRes = (phTime1 != 0 && phTime2 != 0 && phTime1 != phTime2);
   bool haveSup = (plTime1 != 0 && plTime2 != 0 && plTime1 != plTime2);

   datetime tPrev = iTime(_Symbol, PERIOD_CURRENT, 2);
   datetime tCurr = iTime(_Symbol, PERIOD_CURRENT, 1);
   double closePrev = iClose(_Symbol, PERIOD_CURRENT, 2);
   double closeCurr = iClose(_Symbol, PERIOD_CURRENT, 1);

   double atr = GetATR();
   double touchTol = atr * TouchATRMultiplier;
   double bufferPrice = BreakoutBufferPoints * _Point;

   bool   bullSignal = false, bearSignal = false;
   string reasonLong = "", reasonShort = "";

   if(haveRes)
     {
      double resSlope  = (ph1 - ph2) / (double)(phTime1 - phTime2);
      double resAtCurr = LineValueAt(ph1, resSlope, phTime1, tCurr);
      if(DrawTrendlines) DrawLine("TLBreak_Res", phTime2, ph2, tCurr, resAtCurr, clrRed);

      if(!resReacted)
        {
         double resAtPrev = LineValueAt(ph1, resSlope, phTime1, tPrev);
         bool brokeUp = (closePrev <= resAtPrev + bufferPrice && closeCurr > resAtCurr + bufferPrice);
         if(EntryMode != ENTRY_BOUNCE_ONLY && brokeUp)
           {
            bullSignal = true;
            reasonLong = "Breakout @ Resistance";
            resReacted = true;
           }
         else if(EntryMode != ENTRY_BREAKOUT_ONLY && !brokeUp &&
                 TouchingResistance(resAtCurr, touchTol) && BearishPatternConfirmed())
           {
            bearSignal = true;
            reasonShort = "Bounce @ Resistance";
            resReacted = true;
           }
        }
     }

   if(haveSup)
     {
      double supSlope  = (pl1 - pl2) / (double)(plTime1 - plTime2);
      double supAtCurr = LineValueAt(pl1, supSlope, plTime1, tCurr);
      if(DrawTrendlines) DrawLine("TLBreak_Sup", plTime2, pl2, tCurr, supAtCurr, clrLime);

      if(!supReacted)
        {
         double supAtPrev = LineValueAt(pl1, supSlope, plTime1, tPrev);
         bool brokeDown = (closePrev >= supAtPrev - bufferPrice && closeCurr < supAtCurr - bufferPrice);
         if(EntryMode != ENTRY_BOUNCE_ONLY && brokeDown)
           {
            bearSignal = true;
            reasonShort = "Breakout @ Support";
            supReacted = true;
           }
         else if(EntryMode != ENTRY_BREAKOUT_ONLY && !brokeDown &&
                 TouchingSupport(supAtCurr, touchTol) && BullishPatternConfirmed())
           {
            bullSignal = true;
            reasonLong = "Bounce @ Support";
            supReacted = true;
           }
        }
     }

   if(bullSignal) ExecuteEntry(true, reasonLong);
   if(bearSignal) ExecuteEntry(false, reasonShort);
  }
//+------------------------------------------------------------------+
