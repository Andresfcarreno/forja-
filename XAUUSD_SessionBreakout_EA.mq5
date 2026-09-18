//+------------------------------------------------------------------+
//|                                  XAUUSD_SessionBreakout_EA.mq5    |
//|  Gold (XAUUSD) Session Opening Range Breakout EA                  |
//|                                                                    |
//|  Logic:                                                           |
//|   - Tracks the high/low of two configurable "range" windows       |
//|     (default: Asian range, and a pre-NY range).                   |
//|   - After each range closes, watches a "trade window" for a       |
//|     confirmed close beyond the range (breakout).                  |
//|   - A breakout is only traded if it passes ALL enabled            |
//|     confluence filters:                                           |
//|       1) EMA trend filter (higher timeframe)                      |
//|       2) ATR volatility filter (range size vs ATR)                |
//|       3) Previous day High/Low extension filter                   |
//|   - Position size is risk-% based. SL = ATR multiple.             |
//|     TP = SL distance * RR multiple (3, 4 or 5 as requested).      |
//|   - Optional breakeven + ATR trailing once price reaches 1R.      |
//|                                                                    |
//|  IMPORTANT: All hour/minute inputs are in the trading platform's  |
//|  SERVER time (TimeCurrent()), not your local time or GMT. Check   |
//|  your broker's server GMT offset and adjust the session inputs    |
//|  so "Asian range" / "pre-NY range" actually line up with real     |
//|  market hours for your broker.                                   |
//|                                                                    |
//|  This is a template for research/automation purposes. Backtest    |
//|  and forward-test on a demo account before risking real capital. |
//|  No strategy is guaranteed to be profitable.                     |
//+------------------------------------------------------------------+
#property copyright "Custom EA - Session Opening Range Breakout (XAUUSD)"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUTS ======================================
input group "=== General ==="
input bool   EnforceGoldSymbol      = true;        // Only allow running on XAU symbols
input ulong  MagicNumber            = 20260911;
input string TradeComment           = "SessBreak-XAU";
input double MaxSpreadPoints        = 500;          // Max allowed spread, in points
input bool   OnePositionAtATime     = true;         // Block new entries while a position is open

input group "=== Session A (default: Asian range -> London breakout) ==="
input bool   EnableSessionA         = true;
input int    A_RangeStartHour       = 0;
input int    A_RangeStartMin        = 0;
input int    A_RangeEndHour         = 7;
input int    A_RangeEndMin          = 0;
input int    A_TradeWindowEndHour   = 11;
input int    A_TradeWindowEndMin    = 0;

input group "=== Session B (default: pre-NY range -> NY open breakout) ==="
input bool   EnableSessionB         = true;
input int    B_RangeStartHour       = 11;
input int    B_RangeStartMin        = 0;
input int    B_RangeEndHour         = 13;
input int    B_RangeEndMin          = 30;
input int    B_TradeWindowEndHour   = 17;
input int    B_TradeWindowEndMin    = 0;

input group "=== Confluence: EMA Trend Filter ==="
input bool   UseTrendFilter         = true;
input ENUM_TIMEFRAMES TrendTF       = PERIOD_H1;
input int    EMA_Fast_Period        = 50;
input int    EMA_Slow_Period        = 200;

input group "=== Confluence: ATR Volatility Filter ==="
input bool   UseATRFilter           = true;
input int    ATR_Period             = 14;
input double RangeMinATRMult        = 0.5;          // range size must be >= this * ATR
input double RangeMaxATRMult        = 3.0;          // range size must be <= this * ATR

input group "=== Confluence: Previous Day High/Low Filter ==="
input bool   UsePrevDayFilter       = true;
input double MaxExtensionATRMult    = 2.0;          // skip if price already this far beyond prev day H/L

input group "=== Breakout Confirmation ==="
input int    ConfirmationBufferPoints = 200;        // extra buffer beyond range, in points (gold: 200 pts = $2.00 on a 0.01 point broker)

input group "=== Risk / Stop Loss / Take Profit ==="
input double RiskPercent            = 1.0;          // % of account balance risked per trade
input double SL_ATR_Multiplier      = 1.5;          // SL distance = ATR * this
input double RR_Multiplier          = 4.0;          // TP distance = SL distance * this (use 3, 4 or 5)

input group "=== Trade Management ==="
input bool   UseBreakevenTrail      = true;
input double BreakevenAtR           = 1.0;          // move SL to breakeven once price reaches this many R
input double TrailATRMultiplier     = 1.5;          // once past breakeven, trail SL by ATR * this

input group "=== Chart Visuals ==="
input bool   DrawRangeBoxes         = true;

//====================== STATE ========================================
struct SessionState
  {
   double   rangeHigh;
   double   rangeLow;
   bool     rangeReady;
   bool     tradedToday;
   datetime rangeDate;      // date (midnight) the current range belongs to
  };

SessionState sA, sB;

int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;
int atrHandle     = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(EnforceGoldSymbol && StringFind(_Symbol, "XAU") < 0)
     {
      Alert("This EA is restricted to XAU (Gold) symbols. Attach it to a XAUUSD-type chart, or disable EnforceGoldSymbol.");
      return(INIT_FAILED);
     }

   emaFastHandle = iMA(_Symbol, TrendTF, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, TrendTF, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
     {
      Alert("Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   ZeroMemory(sA);
   ZeroMemory(sB);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(atrHandle     != INVALID_HANDLE) IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   if(CopyBuffer(atrHandle, 0, 1, 1, buf) != 1) return(0.0);
   return(buf[0]);
  }

bool TrendAllowsLong()
  {
   if(!UseTrendFilter) return(true);
   double fast[], slow[];
   if(CopyBuffer(emaFastHandle, 0, 1, 1, fast) != 1) return(false);
   if(CopyBuffer(emaSlowHandle, 0, 1, 1, slow) != 1) return(false);
   return(fast[0] > slow[0]);
  }

bool TrendAllowsShort()
  {
   if(!UseTrendFilter) return(true);
   double fast[], slow[];
   if(CopyBuffer(emaFastHandle, 0, 1, 1, fast) != 1) return(false);
   if(CopyBuffer(emaSlowHandle, 0, 1, 1, slow) != 1) return(false);
   return(fast[0] < slow[0]);
  }

bool RangePassesATRFilter(double rangeSize)
  {
   if(!UseATRFilter) return(true);
   double atr = GetATR();
   if(atr <= 0) return(false);
   double ratio = rangeSize / atr;
   return(ratio >= RangeMinATRMult && ratio <= RangeMaxATRMult);
  }

void GetPrevDayHighLow(double &pdHigh, double &pdLow)
  {
   pdHigh = iHigh(_Symbol, PERIOD_D1, 1);
   pdLow  = iLow(_Symbol, PERIOD_D1, 1);
  }

bool PrevDayFilterPassesLong(double breakoutPrice)
  {
   if(!UsePrevDayFilter) return(true);
   double pdHigh, pdLow;
   GetPrevDayHighLow(pdHigh, pdLow);
   double atr = GetATR();
   if(atr <= 0) return(false);
   return((breakoutPrice - pdHigh) <= MaxExtensionATRMult * atr);
  }

bool PrevDayFilterPassesShort(double breakoutPrice)
  {
   if(!UsePrevDayFilter) return(true);
   double pdHigh, pdLow;
   GetPrevDayHighLow(pdHigh, pdLow);
   double atr = GetATR();
   if(atr <= 0) return(false);
   return((pdLow - breakoutPrice) <= MaxExtensionATRMult * atr);
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

int MinutesOfDay(const MqlDateTime &dt)
  {
   return(dt.hour * 60 + dt.min);
  }

//+------------------------------------------------------------------+
void DrawRangeBox(string tag, SessionState &s, color clr)
  {
   if(!DrawRangeBoxes) return;
   string name = "SessRange_" + tag + "_" + TimeToString(s.rangeDate, TIME_DATE);
   if(ObjectFind(0, name) < 0)
     {
      datetime t2 = TimeCurrent() + PeriodSeconds() * 5;
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, s.rangeDate, s.rangeHigh, t2, s.rangeLow);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
void ExecuteTrade(bool isLong, string tag)
  {
   if(OnePositionAtATime && PositionSelect(_Symbol))
      return;

   if(!SpreadOK())
      return;

   double atr = GetATR();
   if(atr <= 0) return;

   double slDist = atr * SL_ATR_Multiplier;
   double price  = isLong ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl     = isLong ? price - slDist : price + slDist;
   double tp     = isLong ? price + slDist * RR_Multiplier : price - slDist * RR_Multiplier;

   double lots = CalcLotSize(slDist);
   if(lots <= 0) return;

   string cmt = TradeComment + "-" + tag;
   if(isLong)
      trade.Buy(lots, _Symbol, price, sl, tp, cmt);
   else
      trade.Sell(lots, _Symbol, price, sl, tp, cmt);
  }

//+------------------------------------------------------------------+
void ProcessSession(SessionState &s, string tag, color boxColor,
                     int rsH, int rsM, int reH, int reM, int twH, int twM,
                     bool isNewBar)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin        = MinutesOfDay(dt);
   int rangeStartMin = rsH * 60 + rsM;
   int rangeEndMin   = reH * 60 + reM;
   int windowEndMin  = twH * 60 + twM;

   MqlDateTime dtDate = dt;
   dtDate.hour = 0; dtDate.min = 0; dtDate.sec = 0;
   datetime today = StructToTime(dtDate);

   // --- Range formation window ---
   if(nowMin >= rangeStartMin && nowMin < rangeEndMin)
     {
      if(s.rangeDate != today)
        {
         s.rangeDate    = today;
         s.rangeHigh    = 0;
         s.rangeLow     = 0;
         s.rangeReady   = false;
         s.tradedToday  = false;
        }
      double h = iHigh(_Symbol, PERIOD_CURRENT, 0);
      double l = iLow(_Symbol, PERIOD_CURRENT, 0);
      if(s.rangeHigh == 0 || h > s.rangeHigh) s.rangeHigh = h;
      if(s.rangeLow  == 0 || l < s.rangeLow)  s.rangeLow  = l;
      return;
     }

   // --- Trade window: range is finalized, watch for breakout ---
   if(nowMin >= rangeEndMin && nowMin < windowEndMin)
     {
      if(s.rangeDate != today || s.rangeHigh <= 0)
         return; // no valid range formed today (e.g. EA started mid-window)

      if(!s.rangeReady)
        {
         s.rangeReady = true;
         DrawRangeBox(tag, s, boxColor);
        }

      if(s.rangeReady && !s.tradedToday && isNewBar)
        {
         double closePrev = iClose(_Symbol, PERIOD_CURRENT, 1);
         double buffer     = ConfirmationBufferPoints * _Point;
         double rangeSize  = s.rangeHigh - s.rangeLow;

         if(closePrev > s.rangeHigh + buffer)
           {
            if(TrendAllowsLong() && RangePassesATRFilter(rangeSize) && PrevDayFilterPassesLong(closePrev))
              {
               ExecuteTrade(true, tag);
               s.tradedToday = true;
              }
           }
         else if(closePrev < s.rangeLow - buffer)
           {
            if(TrendAllowsShort() && RangePassesATRFilter(rangeSize) && PrevDayFilterPassesShort(closePrev))
              {
               ExecuteTrade(false, tag);
               s.tradedToday = true;
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!UseBreakevenTrail) return;
   if(!PositionSelect(_Symbol)) return;
   if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) return;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   long   type  = PositionGetInteger(POSITION_TYPE);

   double atr   = GetATR();
   if(atr <= 0) return;

   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double riskDist = MathAbs(entry - sl);
   if(riskDist <= 0) return;

   double rMultiple = (type == POSITION_TYPE_BUY) ? (price - entry) / riskDist
                                                   : (entry - price) / riskDist;
   if(rMultiple < BreakevenAtR) return;

   double trail = atr * TrailATRMultiplier;
   double newSL = sl;

   if(type == POSITION_TYPE_BUY)
     {
      double candidate = MathMax(entry, price - trail);
      if(candidate > sl) newSL = candidate;
     }
   else
     {
      double candidate = MathMin(entry, price + trail);
      if(candidate < sl) newSL = candidate;
     }

   if(newSL != sl)
      trade.PositionModify(_Symbol, newSL, tp);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime lastBarTime = 0;
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (barTime != lastBarTime);
   if(isNewBar) lastBarTime = barTime;

   ManageOpenPositions();

   if(EnableSessionA)
      ProcessSession(sA, "A", clrDodgerBlue,
                      A_RangeStartHour, A_RangeStartMin, A_RangeEndHour, A_RangeEndMin,
                      A_TradeWindowEndHour, A_TradeWindowEndMin, isNewBar);

   if(EnableSessionB)
      ProcessSession(sB, "B", clrOrange,
                      B_RangeStartHour, B_RangeStartMin, B_RangeEndHour, B_RangeEndMin,
                      B_TradeWindowEndHour, B_TradeWindowEndMin, isNewBar);
  }
//+------------------------------------------------------------------+
