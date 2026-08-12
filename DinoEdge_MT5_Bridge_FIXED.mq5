//+------------------------------------------------------------------+
//| DinoEdge_MT5_Bridge.mq5                                          |
//| Trading Journal <-> MT5 integratsiyasi (Firebase Firestore orqali)|
//+------------------------------------------------------------------+
#property copyright "Sardor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- SOZLAMALAR: shu joyni o'zingiznikiga moslang
input group    "═════ ❗ MAJBURIY: FOYDALANUVCHI KODI ❗ ═════"
input string   UserId           = "";                  // ⚠ Ilovada ko'rsatilgan kodni shu yerga yozing — BO'SH bo'lsa EA ISHLAMAYDI!

input group    "───── Asosiy sozlamalar ─────"
input string   ProjectId        = "treding-jurnal";   // Firebase loyiha ID (projectId)
input int      PollSeconds      = 4;                   // Necha soniyada buyruq tekshirilsin
input ulong    MagicNumber      = 778899;               // EA magic raqami
input double   DefaultSlippage  = 20;                    // Slippage (pips emas, point)
input int      CommandMaxAgeSec = 70;                    // Buyruq shu soniyadan eski bo'lsa BAJARILMAYDI (aloqa uzilib qolgan payt uchun himoya)
input int      HeartbeatSeconds = 10;                    // Har necha soniyada "tirikman" signali yuborilsin (jurnaldagi MT5 indikatori uchun)

string BaseUrl;
string UserBaseUrl;
string UserIdClean;
datetime lastPollTime = 0;
datetime lastHeartbeatTime = 0;

// Terminal/telefon uzilib qolgan vaqtda o'tkazib yuborilgan (SL/TP bilan yopilgan)
// savdolarni qayta tiklash uchun -- oxirgi ko'rilgan deal ticketini saqlab qo'yamiz.
// GlobalVariable terminalda doimiy saqlanadi (EA/terminal qayta ishga tushsa ham yo'qolmaydi).
string LastDealGVName;

//+------------------------------------------------------------------+
int OnInit()
{
   // TUZATISH: foydalanuvchi kodi kiritilmagan bo'lsa EA ishga tushmasin —
   // aks holda uning ma'lumotlari qayerga yozilishini bilmay xato joyga
   // (yoki umuman noto'g'ri) yuborib qo'yishi mumkin edi.
   // Eslatma: `input` o'zgaruvchi o'zgarmas (const) bo'lgani uchun avval
   // oddiy string'ga nusxalab olamiz, keyin uni tozalaymiz.
   UserIdClean = UserId;
   StringTrimLeft(UserIdClean); StringTrimRight(UserIdClean);
   if(StringLen(UserIdClean) == 0)
   {
      Alert("DinoEdge EA: Foydalanuvchi kodi kiritilmagan!\n\nGrafikka o'ng tugma bosing -> Ekspertlar xususiyati -> Inputs bo'limida 'UserId' maydoniga ilovada ko'rsatilgan kodni yozing.");
      Comment("⚠ DinoEdge EA TO'XTATILDI\nSabab: UserId (foydalanuvchi kodi) kiritilmagan.\nInputs bo'limidan kodni kiriting.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   BaseUrl = "https://firestore.googleapis.com/v1/projects/" + ProjectId + "/databases/(default)/documents";
   // TUZATISH: har bir foydalanuvchining ma'lumotlari umumiy (flat)
   // mt5_commands/mt5_events collection'lariga emas, balki
   // /users/{UserId}/mt5_commands va /users/{UserId}/mt5_events kabi
   // ALOHIDA "papka"ga yozilishi uchun — barcha so'rovlarda shu manzil
   // (UserBaseUrl) ishlatiladi, oddiy BaseUrl emas.
   UserBaseUrl = BaseUrl + "/users/" + UserIdClean;
   trade.SetExpertMagicNumber(MagicNumber);
   EventSetTimer(PollSeconds);
   LastDealGVName = "DinoEdge_LastDealTicket_" + IntegerToString(MagicNumber);

   Print("DinoEdge MT5 Bridge ishga tushdi. Foydalanuvchi manzili: ", UserBaseUrl);

   // Uzilib turgan vaqtda (EA o'chgan/telefon o'chgan paytda) SL/TP bilan yopilgan
   // yoki ochilgan, lekin bildirilmagan savdolarni tekshirib, jurnalga yuboramiz.
   ReconcileMissedDeals();

   // Jurnaldagi MT5 indikatori darhol "ulangan" holatini ko'rsatishi uchun
   // ishga tushish zahoti bitta heartbeat yuboramiz.
   SendHeartbeat();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Har PollSeconds da: jurnaldan kelgan buyruqlarni tekshirish       |
//+------------------------------------------------------------------+
void OnTimer()
{
   CheckPendingCommands();

   // Jurnaldagi "MT5" indikatori uchun muntazam "tirikman" signali.
   // Kompyuter/MT5 o'chirilsa yoki EA to'xtasa, bu signal kelishdan
   // to'xtaydi va jurnal ~30 soniyadan keyin avtomatik "aloqa yo'q"
   // (sariq) holatiga o'tadi.
   if(TimeGMT() - lastHeartbeatTime >= HeartbeatSeconds)
   {
      SendHeartbeat();
      lastHeartbeatTime = TimeGMT();
   }
}

//+------------------------------------------------------------------+
//| _ping/ea hujjatiga joriy vaqtni (UTC, millisekund) yozib turadi.  |
//| Jurnal (veb ilova) shu vaqtni kuzatib, "yashil/sariq" indikatorni  |
//| shunga qarab ko'rsatadi.                                          |
//+------------------------------------------------------------------+
void SendHeartbeat()
{
   long nowMs = (long)TimeGMT() * 1000;
   string url = UserBaseUrl + "/_ping/ea?updateMask.fieldPaths=t";
   string body = "{\"fields\":{\"t\":{\"integerValue\":\"" + IntegerToString(nowMs) + "\"}}}";
   HttpRequest("PATCH", url, body);
}

//+------------------------------------------------------------------+
//| Firestore'ga umumiy HTTP so'rov yuborish (WebRequest wrapper)     |
//+------------------------------------------------------------------+
string HttpRequest(string method, string url, string jsonBody)
{
   char postData[];
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";

   if(jsonBody != "")
   {
      // count=-1 (WHOLE_ARRAY) bersak, funksiya '\0' ni o'zi qo'shib beradi,
      // shu holatdagina uni -1 qilib kesib tashlash to'g'ri bo'ladi.
      // Oldingi kodda aniq uzunlik (StringLen) berilgani sababli '\0' umuman
      // qo'shilmagan edi, lekin baribir oxirgi bayt kesib tashlanardi —
      // natijada JSON matnining oxirgi belgisi (masalan yopuvchi "}") yo'qolib,
      // "Invalid JSON payload / Unexpected end of string" xatosiga sabab bo'lardi.
      int len = StringToCharArray(jsonBody, postData, 0, WHOLE_ARRAY, CP_UTF8);
      if(len > 0) ArrayResize(postData, len - 1); // faqat oxiridagi '\0' ni olib tashlaymiz
   }

   ResetLastError();
   int res = WebRequest(method, url, headers, 5000, postData, result, resultHeaders);

   if(res == -1)
   {
      int err = GetLastError();
      Print("WebRequest xato: ", err, " URL: ", url,
            " -- MT5da Tools->Options->Expert Advisors bo'limida WebRequest ruxsatini tekshiring.");
      return "";
   }

   string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   // Firestore javobi ko'pincha "pretty-print" qilingan bo'ladi (colon/vergul dan keyin
   // probel, qatorlar orasida \n bo'ladi). Pastdagi Extract* funksiyalari esa faqat
   // "qattiq" (compact, probelsiz) JSON qidiradi -- shu sabab docId/fieldlar topilmay,
   // buyruqlar "pending" holatida qolib ketardi. Shuning uchun satr ichidagi (qo'shtirnoq
   // orasidagi) belgilarga tegmasdan, faqat strukturaviy bo'shliqlarni olib tashlaymiz.
   response = CompactJson(response);

   if(StringFind(response, "\"error\"") != -1)
   {
      Print("Firestore XATO javobi (", method, " ", url, "): ", response);
   }

   return response;
}

//+------------------------------------------------------------------+
//| JSON matnidagi struktura bo'shliqlarini (probel/\n/\r/\t) olib     |
//| tashlaydi, lekin qo'shtirnoq ICHIDAGI matnga (va \" kabi escape    |
//| ketma-ketliklariga) tegmaydi.                                     |
//+------------------------------------------------------------------+
string CompactJson(string s)
{
   string result = "";
   bool inString = false;
   int len = StringLen(s);
   int i = 0;
   while(i < len)
   {
      string ch = StringSubstr(s, i, 1);

      if(inString && ch == "\\")
      {
         // Escape ketma-ketligini (masalan \" yoki \\) o'zgarishsiz ko'chiramiz
         result += ch;
         i++;
         if(i < len) { result += StringSubstr(s, i, 1); i++; }
         continue;
      }

      if(ch == "\"")
      {
         inString = !inString;
         result += ch;
         i++;
         continue;
      }

      if(!inString && (ch == " " || ch == "\n" || ch == "\r" || ch == "\t"))
      {
         i++; // struktura bo'shlig'i -- tashlab yuboramiz
         continue;
      }

      result += ch;
      i++;
   }
   return result;
}

//+------------------------------------------------------------------+
//| Kutilayotgan (pending) buyruqlarni Firestore'dan olish            |
//+------------------------------------------------------------------+
void CheckPendingCommands()
{
   string url = UserBaseUrl + ":runQuery";
   string body =
      "{"
        "\"structuredQuery\":{"
          "\"from\":[{\"collectionId\":\"mt5_commands\"}],"
          "\"where\":{"
            "\"fieldFilter\":{"
              "\"field\":{\"fieldPath\":\"status\"},"
              "\"op\":\"EQUAL\","
              "\"value\":{\"stringValue\":\"pending\"}"
            "}"
          "},"
          "\"limit\":5"
        "}"
      "}";

   string response = HttpRequest("POST", url, body);
   if(response == "") return;

   //--- VAQTINCHALIK DEBUG: qisqa xulosa (butun JSON emas, jurnal tez to'lib ketmasligi uchun)
   int docCount = 0;
   int scanPos = 0;
   while(true)
   {
      int p = StringFind(response, "\"document\":", scanPos);
      if(p == -1) break;
      docCount++;
      scanPos = p + 11;
   }
   Print("DEBUG poll: topilgan pending buyruqlar soni = ", docCount);

   // Javob bir nechta { "document": {...} } obyektlaridan iborat massiv
   int pos = 0;
   while(true)
   {
      int docPos = StringFind(response, "\"document\":", pos);
      if(docPos == -1) break;

      // Har bir documentni qayta ishlash uchun uning oxirigacha (keyingi "document" boshigacha yoki oxirigacha) kesib olamiz
      int nextDocPos = StringFind(response, "\"document\":", docPos + 10);
      string chunk;
      if(nextDocPos == -1)
         chunk = StringSubstr(response, docPos);
      else
         chunk = StringSubstr(response, docPos, nextDocPos - docPos);

      ProcessCommandDoc(chunk);

      if(nextDocPos == -1) break;
      pos = nextDocPos;
   }
}

//+------------------------------------------------------------------+
//| Bitta buyruq hujjatini qayta ishlash: order ochish + status update|
//+------------------------------------------------------------------+
void ProcessCommandDoc(string chunk)
{
   string docId = ExtractDocId(chunk);
   if(docId == "") { Print("DEBUG: docId topilmadi, chunk: ", chunk); return; }

   // ALOQA UZILGAN PAYTDA YUBORILGAN ESKI BUYRUQLARDAN HIMOYA:
   // Buyruq Firestore'da "createdAt" vaqti bilan yaratiladi. Agar terminal
   // (yoki internet) uzilib qolib, keyin qayta ulanganda "pending" holatdagi
   // eski buyruqlar topilsa -- ularni HOZIRGI bozor holatida bajarish xavfli
   // (buyruq yuborilgan vaqtdagi shart-sharoit allaqachon o'zgargan bo'lishi
   // mumkin). Shu sabab, CommandMaxAgeSec dan eski buyruqlar bajarilmaydi,
   // ularning statusi to'g'ridan-to'g'ri "error" ga o'tkaziladi.
   datetime cmdCreatedAt = ExtractTimestampField(chunk, "createdAt");
   if(cmdCreatedAt > 0)
   {
      long ageSec = (long)(TimeGMT() - cmdCreatedAt);
      if(ageSec > CommandMaxAgeSec)
      {
         Print("DEBUG: buyruq ESKIRGAN (yosh=", ageSec, "s > ", CommandMaxAgeSec,
               "s), BAJARILMAYDI. docId=", docId);
         MarkCommandError(docId, "Buyruq eskirgan (" + IntegerToString(ageSec) +
                           "s oldin yuborilgan) - aloqa uzilib qolgan payt uchun avtomatik bekor qilindi");
         return;
      }
   }

   string type = ExtractStringField(chunk, "type");

   // "close" buyrug'ida symbol/lot yo'q, faqat ticket bo'ladi — alohida yo'l bilan ishlaymiz
   if(type == "close")
   {
      ProcessCloseCommand(docId, chunk);
      return;
   }

   string symbol = ExtractStringField(chunk, "symbol");
   double lot    = ExtractDoubleField(chunk, "lot");
   double sl     = ExtractDoubleField(chunk, "sl");
   double tp     = ExtractDoubleField(chunk, "tp");

   Print("DEBUG: buyruq qayta ishlanmoqda -> docId=", docId, " symbol=", symbol,
         " type=", type, " lot=", lot, " sl=", sl, " tp=", tp);

   if(symbol == "" || lot <= 0)
   {
      Print("DEBUG: symbol yoki lot notogri, jarayon toxtatildi");
      MarkCommandError(docId, "Notogri malumot (symbol/lot)");
      return;
   }

   // Avval statusni "processing" qilib qo'yamiz, ikki marta bajarilmasligi uchun
   MarkCommandProcessing(docId);

   bool ok = false;
   double price = 0;
   if(type == "buy")
   {
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      ok = trade.Buy(lot, symbol, price, sl, tp, "Journal MT5 Bridge");
   }
   else if(type == "sell")
   {
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
      ok = trade.Sell(lot, symbol, price, sl, tp, "Journal MT5 Bridge");
   }
   else
   {
      MarkCommandError(docId, "Nomalum turi: " + type);
      return;
   }

   if(ok)
   {
      // MUHIM TUZATISH: trade.ResultOrder() BUYRUQ (order) ticketini qaytaradi,
      // bu POZITSIYA ticketi bilan BIR XIL BO'LMASLIGI mumkin (ayniqsa hedging
      // hisoblarda). Keyinchalik PositionClose/PositionSelectByTicket aynan
      // POZITSIYA ticketini talab qiladi — shu farq tufayli yopish buyruqlari
      // "pozitsiya topilmadi" xatosi bilan doim muvaffaqiyatsiz tugardi.
      // Shu sabab ochilgandan keyin darhol haqiqiy pozitsiya ticketini qidirib topamiz.
      ulong ticket = FindJustOpenedPositionTicket(symbol);
      if(ticket == 0) ticket = trade.ResultOrder(); // zaxira variant
      Print("DEBUG: savdo MUVAFFAQIYATLI ochildi. Order ticket=", trade.ResultOrder(),
            " -> Pozitsiya ticket=", ticket);
      MarkCommandDone(docId, ticket);
   }
   else
   {
      Print("DEBUG: savdo OCHILMADI. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      MarkCommandError(docId, "OrderSend xato: " + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Endigina ochilgan pozitsiyaning HAQIQIY pozitsiya ticketini      |
//| topish (shu EA/Magic bilan, shu symbolda, eng oxirgi ochilgan).  |
//+------------------------------------------------------------------+
ulong FindJustOpenedPositionTicket(string symbol)
{
   ulong bestTicket = 0;
   long  bestTimeMsc = -1;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      long tm = (long)PositionGetInteger(POSITION_TIME_MSC);
      if(tm > bestTimeMsc)
      {
         bestTimeMsc = tm;
         bestTicket = t;
      }
   }
   return bestTicket;
}

//+------------------------------------------------------------------+
//| Jurnaldan kelgan "yopish" buyrug'ini bajarish (ticket bo'yicha)   |
//+------------------------------------------------------------------+
void ProcessCloseCommand(string docId, string chunk)
{
   double ticketD = ExtractDoubleField(chunk, "ticket");
   ulong  ticket  = (ulong)ticketD;

   // TUZATISH: jurnal "qisman yopish" so'raganda (masalan lotning bir qismini
   // yopish) buyruq bilan birga "lot" maydonini ham yuboradi (kod:
   // closeOrderInMT5(ticket, lot) -> {"type":"close","ticket":...,"lot":...}).
   // Avval bu yerda "lot" maydoni UMUMAN o'qilmas va PositionClose() doim
   // pozitsiyani TO'LIQ yopar edi -- shu sabab qisman yopish ishlamas edi.
   // Endi: agar so'ralgan lot pozitsiyaning haqiqiy hajmidan KICHIK bo'lsa,
   // faqat SHU miqdorda qisman yopamiz (PositionClosePartial). Aks holda
   // (lot berilmagan yoki pozitsiya hajmiga teng/undan katta bo'lsa) -- avval
   // ishlab turgan TO'LIQ yopish yo'li o'zgarishsiz saqlanadi.
   double reqLot = ExtractDoubleField(chunk, "lot");

   Print("DEBUG: yopish buyrug'i qayta ishlanmoqda -> docId=", docId, " ticket=", ticket, " lot=", reqLot);

   if(ticket == 0)
   {
      Print("DEBUG: ticket notogri, jarayon toxtatildi");
      MarkCommandError(docId, "Notogri ticket");
      return;
   }

   // Avval statusni "processing" qilib qo'yamiz, ikki marta bajarilmasligi uchun
   MarkCommandProcessing(docId);

   if(!PositionSelectByTicket(ticket))
   {
      Print("DEBUG: pozitsiya topilmadi (allaqachon yopilgan bo'lishi mumkin), ticket=", ticket);
      MarkCommandError(docId, "Pozitsiya topilmadi: " + IntegerToString((long)ticket));
      return;
   }

   double posVolume = PositionGetDouble(POSITION_VOLUME);
   double minLot     = SymbolInfoDouble(PositionGetString(POSITION_SYMBOL), SYMBOL_VOLUME_MIN);
   double volumeStep = SymbolInfoDouble(PositionGetString(POSITION_SYMBOL), SYMBOL_VOLUME_STEP);

   // Qisman yopish shartlari: lot berilgan, musbat, va pozitsiya hajmidan aniq
   // kichik (bir necha nol o'nlik xato uchun kichik tolerantlik bilan).
   bool isPartial = (reqLot > 0 && reqLot < posVolume - (volumeStep > 0 ? volumeStep / 2 : 0.0000001));

   bool ok;
   if(isPartial)
   {
      // Lotni sembol qadamiga (volume step) mos moslashtiramiz -- aks holda
      // MT5 "noto'g'ri hajm" xatosi bilan rad etishi mumkin.
      double vol = reqLot;
      if(volumeStep > 0) vol = MathRound(vol / volumeStep) * volumeStep;
      if(vol < minLot) vol = minLot;
      if(vol > posVolume) vol = posVolume;

      ok = trade.PositionClosePartial(ticket, vol);
      if(ok)
         Print("DEBUG: pozitsiya QISMAN yopildi. Ticket=", ticket, " yopilgan lot=", vol, " (qolgan=", (posVolume - vol), ")");
      else
         Print("DEBUG: pozitsiya QISMAN YOPILMADI. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else
   {
      ok = trade.PositionClose(ticket);
      if(ok)
         Print("DEBUG: pozitsiya MUVAFFAQIYATLI (TO'LIQ) yopildi. Ticket=", ticket);
      else
         Print("DEBUG: pozitsiya YOPILMADI. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   if(ok)
   {
      MarkCommandDone(docId, ticket);
   }
   else
   {
      MarkCommandError(docId, (isPartial ? "PositionClosePartial xato: " : "PositionClose xato: ") +
                        IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Hujjat statusini yangilash funksiyalari                           |
//+------------------------------------------------------------------+
void MarkCommandProcessing(string docId)
{
   string url = UserBaseUrl + "/mt5_commands/" + docId + "?updateMask.fieldPaths=status";
   string body = "{\"fields\":{\"status\":{\"stringValue\":\"processing\"}}}";
   string resp = HttpRequest("PATCH", url, body);
   Print("DEBUG: MarkCommandProcessing javobi (docId=", docId, "): ", resp);
}

void MarkCommandDone(string docId, ulong ticket)
{
   string url = UserBaseUrl + "/mt5_commands/" + docId +
                "?updateMask.fieldPaths=status&updateMask.fieldPaths=ticket";
   string body = "{\"fields\":{"
                 "\"status\":{\"stringValue\":\"done\"},"
                 "\"ticket\":{\"integerValue\":\"" + IntegerToString((long)ticket) + "\"}"
                 "}}";
   HttpRequest("PATCH", url, body);
}

void MarkCommandError(string docId, string errMsg)
{
   string url = UserBaseUrl + "/mt5_commands/" + docId +
                "?updateMask.fieldPaths=status&updateMask.fieldPaths=errorMsg";
   string body = "{\"fields\":{"
                 "\"status\":{\"stringValue\":\"error\"},"
                 "\"errorMsg\":{\"stringValue\":\"" + JsonEscape(errMsg) + "\"}"
                 "}}";
   HttpRequest("PATCH", url, body);
}

//+------------------------------------------------------------------+
//| Savdo hodisalarini (ochilish/yopilish) jurnalga yuborish          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(magic != (long)MagicNumber) return; // faqat shu EA ochgan savdolar

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double price  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   // TUZATISH: DEAL_PROFIT faqat sof narx harakatidan foydani beradi —
   // swap va komissiyani o'z ichiga OLMAYDI. Shu sabab haqiqatda B/U
   // (kirish = chiqish) qilingan savdo, agar komissiya yoki swap bo'lsa,
   // jurnalda "BU" (pnl=0) deb noto'g'ri ko'rinar edi, holbuki hisobda
   // haqiqiy zarar/foyda bor edi. Endi swap + komissiyani ham qo'shamiz —
   // shunda jurnaldagi pnl MT5 terminaldagi haqiqiy "Net Profit"ga mos keladi.
   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                  + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                  + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   long   posId  = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   string sideStr = (dealType == DEAL_TYPE_BUY) ? "buy" : "sell";
   datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   long msTime = (long)dealTime * 1000;

   if(entry == DEAL_ENTRY_IN)
   {
      SendMT5Event("open", posId, symbol, sideStr, volume, price, 0, 0, msTime, 0);
   }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      SendMT5Event("close", posId, symbol, sideStr, volume, 0, price, profit, 0, msTime);
   }

   // Reconcile funksiyasi shu deal'ni qayta yubormasligi uchun "ko'rilgan" deb belgilaymiz
   if(dealTicket > (ulong)GlobalVariableGet(LastDealGVName))
      GlobalVariableSet(LastDealGVName, (double)dealTicket);
}

//+------------------------------------------------------------------+
//| EA o'chgan/uzilgan paytda sodir bo'lgan (o'tkazib yuborilgan)      |
//| deal'larni tarixdan (HistorySelect) topib, jurnalga qayta yuborish|
//+------------------------------------------------------------------+
void ReconcileMissedDeals()
{
   ulong lastTicket = (ulong)GlobalVariableGet(LastDealGVName);

   // Butun tarixni (akkaunt ochilgandan hozirgacha) tanlaymiz -- faqat shu EA'ning
   // (MagicNumber) va lastTicket'dan KATTA (hali yuborilmagan) deal'larini qayta ishlaymiz.
   if(!HistorySelect(0, TimeCurrent() + 1))
   {
      Print("DEBUG: ReconcileMissedDeals -- HistorySelect muvaffaqiyatsiz");
      return;
   }

   int total = HistoryDealsTotal();
   int sentCount = 0;
   ulong maxTicket = lastTicket;

   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(dealTicket <= lastTicket) continue; // avval yuborilgan

      long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(magic != (long)MagicNumber) { if(dealTicket > maxTicket) maxTicket = dealTicket; continue; }

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      // Kirish/chiqishga aloqasi bo'lmagan deal turlari (balans, komissiya va h.k.) o'tkazib yuboriladi
      if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      {
         if(dealTicket > maxTicket) maxTicket = dealTicket;
         continue;
      }

      string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      double price  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      // TUZATISH: shu yerda ham swap + komissiyani qo'shamiz (yuqoridagi
      // OnTradeTransaction'dagi izohga qarang) — aks holda EA o'chib/qayta
      // ulanganda "o'tkazib yuborilgan" close hodisalari noto'g'ri (kam) pnl
      // bilan yuborilib, jurnaldagi B/U klassifikatsiyasi xato chiqar edi.
      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                     + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                     + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      long   posId  = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      string sideStr = (dealType == DEAL_TYPE_BUY) ? "buy" : "sell";
      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      long msTime = (long)dealTime * 1000;

      if(entry == DEAL_ENTRY_IN)
      {
         Print("DEBUG: Reconcile -- o'tkazib yuborilgan OPEN topildi, ticket=", dealTicket, " posId=", posId);
         SendMT5Event("open", posId, symbol, sideStr, volume, price, 0, 0, msTime, 0);
      }
      else
      {
         Print("DEBUG: Reconcile -- o'tkazib yuborilgan CLOSE topildi, ticket=", dealTicket, " posId=", posId, " profit=", profit);
         SendMT5Event("close", posId, symbol, sideStr, volume, 0, price, profit, 0, msTime);
      }

      sentCount++;
      if(dealTicket > maxTicket) maxTicket = dealTicket;
   }

   if(maxTicket > lastTicket)
      GlobalVariableSet(LastDealGVName, (double)maxTicket);

   Print("DEBUG: ReconcileMissedDeals tugadi. Qayta yuborilgan hodisalar soni = ", sentCount);
}

//+------------------------------------------------------------------+
//| mt5_events collection'iga yangi hujjat yaratish                   |
//+------------------------------------------------------------------+
void SendMT5Event(string eventType, long ticket, string symbol, string side,
                   double lot, double openPrice, double closePrice, double profit,
                   long openMs, long closeMs)
{
   string url = UserBaseUrl + "/mt5_events";

   string fields = "\"eventType\":{\"stringValue\":\"" + eventType + "\"},";
   fields += "\"ticket\":{\"stringValue\":\"" + IntegerToString(ticket) + "\"},";
   fields += "\"symbol\":{\"stringValue\":\"" + symbol + "\"},";
   fields += "\"type\":{\"stringValue\":\"" + side + "\"},";
   fields += "\"lot\":{\"doubleValue\":" + DoubleToString(lot, 2) + "},";
   fields += "\"processed\":{\"booleanValue\":false},";

   if(eventType == "open")
   {
      fields += "\"openPrice\":{\"doubleValue\":" + DoubleToString(openPrice, 5) + "},";
      fields += "\"openTime\":{\"integerValue\":\"" + IntegerToString(openMs) + "\"}";
   }
   else
   {
      fields += "\"closePrice\":{\"doubleValue\":" + DoubleToString(closePrice, 5) + "},";
      fields += "\"profit\":{\"doubleValue\":" + DoubleToString(profit, 2) + "},";
      fields += "\"closeTime\":{\"integerValue\":\"" + IntegerToString(closeMs) + "\"}";
   }

   string body = "{\"fields\":{" + fields + "}}";
   HttpRequest("POST", url, body);
}

//+------------------------------------------------------------------+
//| Yordamchi JSON parsing funksiyalari (Firestore REST formati uchun)|
//+------------------------------------------------------------------+
string ExtractDocId(string chunk)
{
   int namePos = StringFind(chunk, "\"name\":\"");
   if(namePos == -1) return "";
   int start = namePos + 8;
   int endQ = StringFind(chunk, "\"", start);
   if(endQ == -1) return "";
   string fullPath = StringSubstr(chunk, start, endQ - start);
   int lastSlash = StringFindRev(fullPath, "/");
   if(lastSlash == -1) return fullPath;
   return StringSubstr(fullPath, lastSlash + 1);
}

int StringFindRev(string text, string sub)
{
   int last = -1;
   int pos = 0;
   while(true)
   {
      int found = StringFind(text, sub, pos);
      if(found == -1) break;
      last = found;
      pos = found + 1;
   }
   return last;
}

string ExtractStringField(string chunk, string fieldName)
{
   string marker = "\"" + fieldName + "\":{\"stringValue\":\"";
   int pos = StringFind(chunk, marker);
   if(pos == -1) return "";
   int start = pos + StringLen(marker);
   int endQ = StringFind(chunk, "\"", start);
   if(endQ == -1) return "";
   return StringSubstr(chunk, start, endQ - start);
}

double ExtractDoubleField(string chunk, string fieldName)
{
   // doubleValue yoki integerValue bo'lishi mumkin
   string markerD = "\"" + fieldName + "\":{\"doubleValue\":";
   int pos = StringFind(chunk, markerD);
   if(pos != -1)
   {
      int start = pos + StringLen(markerD);
      int endC = StringFind(chunk, "}", start);
      string valStr = StringSubstr(chunk, start, endC - start);
      return StringToDouble(valStr);
   }
   string markerI = "\"" + fieldName + "\":{\"integerValue\":\"";
   pos = StringFind(chunk, markerI);
   if(pos != -1)
   {
      int start = pos + StringLen(markerI);
      int endQ = StringFind(chunk, "\"", start);
      string valStr = StringSubstr(chunk, start, endQ - start);
      return StringToDouble(valStr);
   }
   return 0;
}

//+------------------------------------------------------------------+
//| "YYYY-MM-DDTHH:MM:SS(.ffffff)?Z" -> MQL5 datetime (UTC)          |
//+------------------------------------------------------------------+
datetime ParseIsoTimestamp(string iso)
{
   if(StringLen(iso) < 19) return 0;
   string datePart = StringSubstr(iso, 0, 10); // YYYY-MM-DD
   string timePart = StringSubstr(iso, 11, 8); // HH:MM:SS
   StringReplace(datePart, "-", ".");
   string mqlStr = datePart + " " + timePart;
   datetime result = StringToTime(mqlStr);
   return result;
}

//+------------------------------------------------------------------+
//| Firestore "timestampValue" (ISO8601, masalan                     |
//| "2026-08-12T00:41:22.123456789Z") maydonini o'qib, MQL5 datetime  |
//| (GMT/UTC) ga aylantiradi. Topilmasa 0 qaytaradi.                  |
//+------------------------------------------------------------------+
datetime ExtractTimestampField(string chunk, string fieldName)
{
   string marker = "\"" + fieldName + "\":{\"timestampValue\":\"";
   int pos = StringFind(chunk, marker);
   if(pos == -1) return 0;
   int start = pos + StringLen(marker);
   int endQ = StringFind(chunk, "\"", start);
   if(endQ == -1) return 0;
   string iso = StringSubstr(chunk, start, endQ - start);
   return ParseIsoTimestamp(iso);
}

string JsonEscape(string s)
{
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", " ");
   StringReplace(r, "\r", " ");
   return r;
}
//+------------------------------------------------------------------+
