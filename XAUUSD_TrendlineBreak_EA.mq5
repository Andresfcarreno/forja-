//+------------------------------------------------------------------+
//|                                   XAUUSD_TrendlineBreak_EA.mq5    |
//|  Gold (XAUUSD) Trendline Break EA - stop & reverse                |
//|                                                                    |
//|  Own implementation of the classic pivot-based dynamic trendline  |
//|  break concept (same idea as oscillators that plot a green dot on |
//|  a bullish trendline break and a red dot on a bearish break).     |
//|  This is NOT a port of any third-party proprietary indicator -    |
//|  it is written independently so it can run fully automated.       |
//|                                                                    |
//|  Logic:                                                           |
//|   - Detect confirmed pivot highs/lows (PivotLookback bars each     |
//|     side).                                                        |
//|   - Project a resistance line through the last 2 pivot highs and  |
//|     a support line through the last 2 pivot lows.                 |
//|   - Bullish break: a closed bar crosses above the resistance      |
//|     line  -> close any short, open long.                          |
//|   - Bearish break: a closed bar crosses below the support line    |
//|     -> close any long, open short.                                |
//|   - Every entry carries an ATR-based SL and an R:R-based TP, so   |
//|     the position also closes automatically when the profit        |
//|     target is reached, not only on the opposite signal.           |
//|                                                                    |
//|  Educational / research template. Backtest and forward-test on    |
//|  demo before using with real capital. No strategy is guaranteed   |
//|  to be profitable.                                                |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Trendline Break Stop & Reverse (XAUUSD)"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUTS ======================================
input group "=== General ==="
input bool   EnforceGoldSymbol      = true;
input ulong  MagicNumber            = 20260912;
input string TradeComment           = "TLBreak-XAU";
input double MaxSpreadPoints        = 500;

input group "=== Trendline ==="
input int    PivotLookback          = 5;      // bars each side to confirm a pivot

input group "=== Risk / Stop Loss / Take Profit ==="
input double RiskPercent            = 1.0;
input double SL_ATR_Multiplier      = 1.5;
input double RR_Multiplier          = 3.0;
input int    ATR_Period             = 14;

input group "=== Chart Visuals ==="
input bool   DrawTrendlines         = true;

//====================== STATE ========================================
double ph1 = 0, ph2 = 0;
datetime phTime1 = 0, phTime2 = 0;
double pl1 = 0, pl2 = 0;
datetime plTime1 = 0, plTime2 = 0;

bool resBroken = false;
bool supBroken = false;

datetime lastCheckedPivotBarTime = 0; // avoids re-processing the same closed bar's pivot check twice

int atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(EnforceGoldSymbol && StringFind(_Symbol, "XAU") < 0)
     {
      Alert("This EA is restricted to XAU (Gold) symbols. Attach it to a XAUUSD-type chart, or disable EnforceGoldSymbol.");
      return(INIT_FAILED);
     }

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
     {
      Alert("Failed to create ATR handle.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
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

double CalcLotSize(double slDistancePrice)
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;

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
void ExecuteEntry(bool isLong)
  {
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

   if(isLong)
      trade.Buy(lots, _Symbol, price, sl, tp, TradeComment);
   else
      trade.Sell(lots, _Symbol, price, sl, tp, TradeComment);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime lastBarTime = 0;
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (barTime != lastBarTime);
   if(!isNewBar) return;
   lastBarTime = barTime;

   // --- Update pivots (checked once per new closed bar) ---
   double newPh, newPl;
   datetime newPhTime, newPlTime;

   if(IsPivotHigh(newPh, newPhTime) && newPhTime != phTime1)
     {
      ph2 = ph1; phTime2 = phTime1;
      ph1 = newPh; phTime1 = newPhTime;
      resBroken = false;
     }

   if(IsPivotLow(newPl, newPlTime) && newPlTime != plTime1)
     {
      pl2 = pl1; plTime2 = plTime1;
      pl1 = newPl; plTime1 = newPlTime;
      supBroken = false;
     }

   // --- Compute trendline projections and check for a break on the last two closed bars ---
   bool haveRes = (phTime1 != 0 && phTime2 != 0 && phTime1 != phTime2);
   bool haveSup = (plTime1 != 0 && plTime2 != 0 && plTime1 != plTime2);

   datetime tPrev = iTime(_Symbol, PERIOD_CURRENT, 2);
   datetime tCurr = iTime(_Symbol, PERIOD_CURRENT, 1);
   double closePrev = iClose(_Symbol, PERIOD_CURRENT, 2);
   double closeCurr = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool bullBreak = false;
   bool bearBreak = false;

   if(haveRes)
     {
      double resSlope = (ph1 - ph2) / (double)(phTime1 - phTime2);
      double resAtCurr = LineValueAt(ph1, resSlope, phTime1, tCurr);
      if(DrawTrendlines) DrawLine("TLBreak_Res", phTime2, ph2, tCurr, resAtCurr, clrRed);
      if(!resBroken)
        {
         double resAtPrev = LineValueAt(ph1, resSlope, phTime1, tPrev);
         if(closePrev <= resAtPrev && closeCurr > resAtCurr)
           {
            bullBreak = true;
            resBroken = true;
           }
        }
     }

   if(haveSup)
     {
      double supSlope = (pl1 - pl2) / (double)(plTime1 - plTime2);
      double supAtCurr = LineValueAt(pl1, supSlope, plTime1, tCurr);
      if(DrawTrendlines) DrawLine("TLBreak_Sup", plTime2, pl2, tCurr, supAtCurr, clrLime);
      if(!supBroken)
        {
         double supAtPrev = LineValueAt(pl1, supSlope, plTime1, tPrev);
         if(closePrev >= supAtPrev && closeCurr < supAtCurr)
           {
            bearBreak = true;
            supBroken = true;
           }
        }
     }

   if(bullBreak) ExecuteEntry(true);
   if(bearBreak) ExecuteEntry(false);
  }
//+------------------------------------------------------------------+
