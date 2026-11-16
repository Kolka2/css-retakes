// Grenades: how many a player gets and which ones.
// Included only from retakes_allocator.sp.
//
// Two things are decided separately:
//  - how many: a random number from the range of the round type, or from
//    sm_retakes_alloc_nades_count if it is set;
//  - which ones: random (sm_retakes_alloc_nades "random", and always for bots), or as the
//    player set it up in the !guns menu (sm_retakes_alloc_nades "choice"):
//      * random every round (the default);
//      * a list in the order of priority: the player gets the first N grenades of it;
//      * asked every round: a menu opens when the loadouts are built (in the pause after
//        round_end) and stays usable until the end of the freeze time; what was not
//        picked by then is given at random.

// Everything a CS:S player can carry: an HE grenade, two flashbangs and a smoke grenade.
// The letters are the ones Retakes_SetPlayerInfo understands.
char g_NadePool[] = "hffs";
#define MAX_NADES 4

// Menu item info prefixes of the grenade picker: the saved list or this round's picks.
#define PICK_LIST 'l'
#define PICK_ROUND 'r'

// The saved list of a player in the order of priority; empty = random every round.
char g_NadeList[MAXPLAYERS+1][NADE_STRING_LENGTH];
// If the player picks the grenades in a menu every round instead.
bool g_NadeAsk[MAXPLAYERS+1];

// For a player that is asked every round: how many grenades the round allows and what
// has been picked so far.
int g_RoundNadeLimit[MAXPLAYERS+1];
char g_RoundNadePicks[MAXPLAYERS+1][NADE_STRING_LENGTH];

// True from the moment the loadouts are built to the end of the freeze time.
bool g_NadePickOpen;
// True from round_start to round_end: retakes has handed out the stored loadouts, so a
// grenade picked now has to be given directly.
bool g_RoundStarted;

// The "grenades for this round" menu a client has on the screen (null if none); it is
// closed when the freeze time ends.
Menu g_RoundPickerMenu[MAXPLAYERS+1];
// The player closed that menu (or let it time out): it is not shown again in this round.
bool g_RoundPickerDismissed[MAXPLAYERS+1];
// Runs while the grenades of a round can be picked: see OfferRoundNades.
Handle g_hRoundPickerTimer;
// True while a grenade is being given to the client: see Hook_NadeWeaponSwitch.
bool g_GivingNade[MAXPLAYERS+1];

// sm_retakes_alloc_nades_count, parsed.
bool g_NadeCountOverride;
int g_NadeCountMin;
int g_NadeCountMax;

Handle g_hNadeListCookie;
Handle g_hNadeAskCookie;

void RegisterNadeCookies() {
    g_hNadeListCookie = RegClientCookie("retakes_alloc_nades", "", CookieAccess_Private);
    g_hNadeAskCookie = RegClientCookie("retakes_alloc_nadesask", "", CookieAccess_Private);
}

void ResetNades(int client) {
    g_NadeList[client][0] = '\0';
    g_NadeAsk[client] = false;
    g_RoundNadeLimit[client] = 0;
    g_RoundNadePicks[client][0] = '\0';
}

/**
 * Returns if one more grenade of a kind fits into a set: a player carries at most as many
 * of a kind as g_NadePool has (two flashbangs, one of the others).
 */
static bool CanAddNade(const char[] nades, int nade) {
    int have = 0;
    for (int i = 0; nades[i] != '\0'; i++) {
        if (nades[i] == nade) {
            have++;
        }
    }
    int allowed = 0;
    for (int i = 0; i < MAX_NADES; i++) {
        if (g_NadePool[i] == nade) {
            allowed++;
        }
    }
    return have < allowed;
}

static void AppendNade(char nades[NADE_STRING_LENGTH], int nade) {
    int length = strlen(nades);
    nades[length] = nade;
    nades[length + 1] = '\0';
}

void LoadNades(int client) {
    // The cookie is only trusted as far as it makes a set a player can carry.
    char saved[NADE_STRING_LENGTH];
    GetClientCookie(client, g_hNadeListCookie, saved, sizeof(saved));
    g_NadeList[client][0] = '\0';
    for (int i = 0; saved[i] != '\0'; i++) {
        if (CanAddNade(g_NadeList[client], saved[i])) {
            AppendNade(g_NadeList[client], saved[i]);
        }
    }
    g_NadeAsk[client] = GetCookieBool(client, g_hNadeAskCookie);
}

/**
 * Parses sm_retakes_alloc_nades_count: empty (the range of the round type is used), a
 * number ("1") or a range ("0-4").
 */
void ParseNadeCount(const char[] value) {
    char text[16];
    strcopy(text, sizeof(text), value);
    TrimString(text);

    g_NadeCountOverride = false;
    if (text[0] == '\0') {
        return;
    }

    char parts[2][8];
    int fields = ExplodeString(text, "-", parts, sizeof(parts), sizeof(parts[]));
    int min = StringToInt(parts[0]);
    int max = (fields >= 2) ? StringToInt(parts[1]) : min;
    if (min < 0 || max < min || max > MAX_NADES || !IsCharNumeric(text[0])) {
        LogError("sm_retakes_alloc_nades_count \"%s\" is not empty, a number or \"min-max\" within 0-%d; the round types decide",
                 value, MAX_NADES);
        return;
    }

    g_NadeCountOverride = true;
    g_NadeCountMin = min;
    g_NadeCountMax = max;
}

static bool PlayersChooseNades() {
    char mode[16];
    g_hNadesCvar.GetString(mode, sizeof(mode));
    return StrEqual(mode, "choice", false);
}

static void RandomNades(int count, char nades[NADE_STRING_LENGTH]) {
    int order[MAX_NADES];
    for (int i = 0; i < MAX_NADES; i++) {
        order[i] = i;
    }
    ShuffleInts(order, MAX_NADES);

    for (int i = 0; i < count; i++) {
        nades[i] = g_NadePool[order[i]];
    }
    nades[count] = '\0';
}

/**
 * Writes the grenades of one player for a round of the given type. A player that is asked
 * every round gets none here: OfferRoundNades() opens the menu when everybody is done,
 * and Nades_OnFreezeEnd() gives random ones in place of the grenades that were not picked.
 */
void PickNades(int client, int type, char nades[NADE_STRING_LENGTH]) {
    int count = g_NadeCountOverride ? GetRandomInt(g_NadeCountMin, g_NadeCountMax)
                                    : GetRandomInt(g_TypeNadesMin[type], g_TypeNadesMax[type]);

    if (IsFakeClient(client) || !PlayersChooseNades()) {
        RandomNades(count, nades);
    } else if (g_NadeAsk[client]) {
        nades[0] = '\0';
        g_RoundNadeLimit[client] = count;
        AllocDebug("nades: %N is asked, %d grenade(s) in this round", client, count);
    } else if (g_NadeList[client][0] == '\0') {
        RandomNades(count, nades);
    } else {
        // the first "count" grenades of the list; strcopy counts the terminator
        strcopy(nades, count + 1, g_NadeList[client]);
    }
}

/**
 * Forgets the picks of the previous round. Called before the loadouts are built.
 */
void ResetRoundNades() {
    for (int i = 1; i <= MaxClients; i++) {
        g_RoundNadeLimit[i] = 0;
        g_RoundNadePicks[i][0] = '\0';
        g_RoundPickerDismissed[i] = false;
    }
}

/**
 * Returns if a player should be looking at the grenade menu of the round: the grenades
 * can still be picked, some are left to pick, and the player did not close the menu.
 */
static bool WantsRoundPicker(int client) {
    return g_NadePickOpen && IsPlayer(client) && !g_RoundPickerDismissed[client]
        && strlen(g_RoundNadePicks[client]) < g_RoundNadeLimit[client];
}

/**
 * Shows the grenade menu of the round to everybody who should see it and has no menu on
 * the screen. A SourceMod menu the player has open (!guns, any other plugin) is never
 * replaced: the grenade menu comes when that one is closed. Menus sent past SourceMod
 * (MenuSource_External) are not waited for: see HideClientMenu().
 */
static void ShowPendingRoundPickers() {
    for (int i = 1; i <= MaxClients; i++) {
        if (!WantsRoundPicker(i)) {
            continue;
        }
        MenuSource source = GetClientMenu(i);
        if (source == MenuSource_None || source == MenuSource_External) {
            ShowNadePicker(i, PICK_ROUND);
        }
    }
}

/**
 * Opens the grenade menu for the players that are asked every round. Called when the
 * loadouts of the round are built. While the grenades can be picked, a timer brings the
 * menu to those who could not see it at once.
 */
void OfferRoundNades() {
    g_NadePickOpen = true;
    AllocDebug("nades: the grenades of the round can be picked (round started: %d)", g_RoundStarted);
    ShowPendingRoundPickers();
    if (g_hRoundPickerTimer == null) {
        g_hRoundPickerTimer = CreateTimer(0.5, Timer_RoundPickers, _, TIMER_REPEAT);
    }
}

public Action Timer_RoundPickers(Handle timer) {
    if (!g_NadePickOpen) {
        g_hRoundPickerTimer = null;
        return Plugin_Stop;
    }
    ShowPendingRoundPickers();
    return Plugin_Continue;
}

/**
 * A map change ends a round without round_end.
 */
void Nades_OnMapStart() {
    g_RoundStarted = false;
    g_NadePickOpen = false;
}

void Nades_OnRoundStart() {
    g_RoundStarted = true;
    AllocDebug("event: round_start (grenades can be picked: %d)", g_NadePickOpen);
}

/**
 * The freeze time is over: nobody picks grenades any more, and a player that was asked
 * and did not pick all of the grenades in time gets random ones for the rest.
 */
void Nades_OnFreezeEnd() {
    AllocDebug("event: round_freeze_end (grenades can be picked: %d, round started: %d, live: %d)",
               g_NadePickOpen, g_RoundStarted, Retakes_Live());

    // A freeze end that comes before the round the loadouts were built for has started
    // (around a game restart) is not the one that closes the picking.
    if (!g_RoundStarted) {
        return;
    }

    // (not live: a warmup was started after the loadouts had been built)
    if (g_NadePickOpen && Retakes_Live()) {
        for (int i = 1; i <= MaxClients; i++) {
            if (g_RoundNadeLimit[i] > 0 && IsPlayer(i) && IsPlayerAlive(i) && FillRoundPicks(i)) {
                AllocDebug("nades: %N did not pick in time, now has \"%s\"", i, g_RoundNadePicks[i]);
                TellPhrase(i, "NadesAutoPicked");
            }
        }
    }
    g_NadePickOpen = false;

    // The menu of the round has nothing to offer any more.
    for (int i = 1; i <= MaxClients; i++) {
        Menu menu = g_RoundPickerMenu[i];
        if (menu != null) {
            g_RoundPickerMenu[i] = null;
            menu.Cancel();
            AllocDebug("nades: menu of the round of client %d closed at the freeze end", i);
            if (IsClientInGame(i) && GetClientMenu(i) == MenuSource_None) {
                HideClientMenu(i);
            }
        }
    }
}

/**
 * Takes a cancelled menu off the screen of a client. Cancelling a menu only ends it on
 * the server: on a live CS:S server it stayed on the screen for about 4 more seconds.
 */
static void HideClientMenu(int client) {
    if (GetUserMessageId("ShowMenu") == INVALID_MESSAGE_ID) {
        return;
    }

    // A ShowMenu message with no valid keys makes the CS:S client hide the menu it is
    // showing, at once (checked on a live server). An empty SourceMod panel does not: it
    // flashed as an empty frame for its second.
    //
    // SourceMod takes the message for a menu of somebody else (MenuSource_External). With
    // a display time of 0 that "menu" never ended, and the menu of the round, which did
    // not replace other menus, was not shown in the next rounds (seen on a live server).
    // CSS-VERIFY: with a display time of one second SourceMod forgets it after a second.
    // ShowPendingRoundPickers() does not depend on that: it shows the menu over an
    // external one.
    Handle message = StartMessageOne("ShowMenu", client, USERMSG_RELIABLE);
    if (message != null) {
        BfWrite bf = UserMessageToBfWrite(message);
        bf.WriteShort(0); // valid keys
        bf.WriteChar(1);  // display time, seconds
        bf.WriteByte(0);  // more parts to come
        bf.WriteString("");
        EndMessage();
    }
}

void Nades_OnRoundEnd() {
    AllocDebug("event: round_end");
    g_RoundStarted = false;
    g_NadePickOpen = false;
}

/**
 * Gives a client one grenade by its letter.
 */
static void GiveNade(int client, int nade) {
    g_GivingNade[client] = true;
    switch (nade) {
        case 'h': GivePlayerItem(client, "weapon_hegrenade");
        case 'f': GivePlayerItem(client, "weapon_flashbang");
        case 's': GivePlayerItem(client, "weapon_smokegrenade");
    }
    g_GivingNade[client] = false;
}

void Nades_HookClient(int client) {
    SDKHook(client, SDKHook_WeaponSwitch, Hook_NadeWeaponSwitch);
}

/**
 * The game takes a new grenade into the hands of a player that holds the C4 (seen on a
 * live server: it broke the planting of the bomb; other weapons stay in the hands). No
 * weapon switch is allowed while the plugin gives a grenade: the switch happens inside
 * the GivePlayerItem call and goes through this hook (checked on a live CS:S server).
 */
public Action Hook_NadeWeaponSwitch(int client, int weapon) {
    return g_GivingNade[client] ? Plugin_Handled : Plugin_Continue;
}

/**
 * Adds one grenade to what a player that is asked every round has in this round.
 */
static void DeliverRoundPick(int client, int nade) {
    AppendNade(g_RoundNadePicks[client], nade);

    if (g_RoundStarted) {
        // CSS-VERIFY: a grenade given with GivePlayerItem during the freeze time, or at
        // round_freeze_end, shows up in the player's inventory (a second flashbang as
        // well), and round_freeze_end fires every round, so nobody can pick grenades in
        // the middle of a round.
        if (IsPlayerAlive(client)) {
            GiveNade(client, nade);
        }
    } else {
        // Retakes has not handed out the loadouts yet: the pick goes into the stored one.
        char primary[WEAPON_STRING_LENGTH];
        char secondary[WEAPON_STRING_LENGTH];
        char nades[NADE_STRING_LENGTH];
        int health, armor;
        bool helmet, kit;
        Retakes_GetPlayerInfo(client, primary, secondary, nades, health, armor, helmet, kit);
        Retakes_SetPlayerInfo(client, primary, secondary, g_RoundNadePicks[client], health, armor, helmet, kit);
    }
}

/**
 * Adds the grenades of a set, in its order, to this round's picks of a player, as long as
 * the round allows more and the player can carry them. Returns if anything was added.
 */
static bool AddRoundPicksFrom(int client, const char[] nades) {
    bool added = false;
    for (int i = 0; nades[i] != '\0' && strlen(g_RoundNadePicks[client]) < g_RoundNadeLimit[client]; i++) {
        if (CanAddNade(g_RoundNadePicks[client], nades[i])) {
            DeliverRoundPick(client, nades[i]);
            added = true;
        }
    }
    return added;
}

/**
 * Gives a player that is asked every round random grenades in place of the ones that were
 * not picked: all of them if the menu was ignored, the rest if only some were picked.
 * Returns if anything was added.
 */
static bool FillRoundPicks(int client) {
    char nades[NADE_STRING_LENGTH];
    RandomNades(MAX_NADES, nades);
    return AddRoundPicksFrom(client, nades);
}


/**
 * A player that is asked every round picked a grenade in the menu.
 * Returns if the player may pick another one.
 */
static bool AddRoundPick(int client, int nade) {
    if (!g_NadePickOpen) {
        TellPhrase(client, "NadesTooLate");
        return false;
    }
    if (strlen(g_RoundNadePicks[client]) >= g_RoundNadeLimit[client]
        || !CanAddNade(g_RoundNadePicks[client], nade)) {
        return false;
    }
    DeliverRoundPick(client, nade);

    return strlen(g_RoundNadePicks[client]) < g_RoundNadeLimit[client];
}

/***********************
 *                     *
 *        Menus        *
 *                     *
 ***********************/

/**
 * Writes a set of grenades as text ("Flash, Smoke"); "random every round" for an empty one.
 */
static void FormatNades(int client, const char[] nades, char[] buffer, int size) {
    if (nades[0] == '\0') {
        Format(buffer, size, "%T", "NadesRandom", client);
        return;
    }

    buffer[0] = '\0';
    char phrase[16];
    for (int i = 0; nades[i] != '\0'; i++) {
        Format(phrase, sizeof(phrase), "Nade_%c", nades[i]);
        Format(buffer, size, "%s%s%T", buffer, (i > 0) ? ", " : "", phrase, client);
    }
}

/**
 * Writes what the player has set up for the grenades, for the menu lines.
 */
static void FormatNadeSetting(int client, char[] buffer, int size) {
    if (g_NadeAsk[client]) {
        Format(buffer, size, "%T", "NadesEveryRound", client);
    } else {
        FormatNades(client, g_NadeList[client], buffer, size);
    }
}

/**
 * Adds the grenade line to the main !guns menu, if the players may choose grenades.
 */
void AddNadesMenuItem(Menu menu, int client, const char[] info) {
    if (!PlayersChooseNades()) {
        return;
    }
    char setting[96];
    char text[128];
    FormatNadeSetting(client, setting, sizeof(setting));
    Format(text, sizeof(text), "%T", "MenuNades", client, setting);
    menu.AddItem(info, text);
}

/**
 * The grenade settings of a player.
 */
void ShowNadesMenu(int client) {
    Menu menu = new Menu(MenuHandler_Nades);
    char setting[96];
    FormatNadeSetting(client, setting, sizeof(setting));
    menu.SetTitle("%T", "NadesTitle", client, setting);

    char text[96];
    Format(text, sizeof(text), "%T", "NadesRandom", client);
    menu.AddItem("random", text);
    Format(text, sizeof(text), "%T", "NadesBuildList", client);
    menu.AddItem("list", text);
    Format(text, sizeof(text), "%T", "NadesEveryRound", client);
    menu.AddItem("ask", text);

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_LENGTH);
}

static void SaveNadeSetting(int client, bool ask) {
    g_NadeAsk[client] = ask;
    SetCookieBool(client, g_hNadeAskCookie, ask);
    SetClientCookie(client, g_hNadeListCookie, g_NadeList[client]);
}

public int MenuHandler_Nades(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "random")) {
            g_NadeList[client][0] = '\0';
            SaveNadeSetting(client, false);
            ShowNadesMenu(client);
        } else if (StrEqual(info, "list")) {
            // a new list is started from scratch
            g_NadeList[client][0] = '\0';
            SaveNadeSetting(client, false);
            ShowNadePicker(client, PICK_LIST);
        } else if (StrEqual(info, "ask")) {
            SaveNadeSetting(client, true);
            ShowNadesMenu(client);
        }
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowGunsMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

/**
 * The grenade picker: one grenade per click, for the saved list (PICK_LIST) or for this
 * round (PICK_ROUND). The item info is the target followed by the grenade letter.
 */
static void ShowNadePicker(int client, int target) {
    bool round = (target == PICK_ROUND);
    int picked = strlen(round ? g_RoundNadePicks[client] : g_NadeList[client]);
    int limit = round ? g_RoundNadeLimit[client] : MAX_NADES;

    char current[96];
    FormatNades(client, round ? g_RoundNadePicks[client] : g_NadeList[client], current, sizeof(current));

    Menu menu = new Menu(MenuHandler_NadePicker);
    if (picked == 0) {
        menu.SetTitle("%T", round ? "NadesRoundTitle" : "NadesListTitle", client, picked, limit);
    } else {
        menu.SetTitle("%T\n%s", round ? "NadesRoundTitle" : "NadesListTitle", client, picked, limit, current);
    }

    static char kinds[] = "hfs";
    char info[4];
    char phrase[16];
    char text[64];
    for (int i = 0; kinds[i] != '\0'; i++) {
        if (CanAddNade(round ? g_RoundNadePicks[client] : g_NadeList[client], kinds[i])) {
            Format(info, sizeof(info), "%c%c", target, kinds[i]);
            Format(phrase, sizeof(phrase), "Nade_%c", kinds[i]);
            Format(text, sizeof(text), "%T", phrase, client);
            menu.AddItem(info, text);
        }
    }

    menu.ExitBackButton = !round;
    bool shown = menu.Display(client, MENU_TIME_LENGTH);
    if (round) {
        AllocDebug("nades: menu of the round (%d/%d) -> %N, shown: %d", picked, limit, client, shown);
        if (shown) {
            g_RoundPickerMenu[client] = menu;
        }
    }
}

public int MenuHandler_NadePicker(Menu menu, MenuAction action, int param1, int param2) {
    // The menu is gone from the screen. The handle is compared because a menu replaced by
    // a new one reports its cancellation too, and must not clear the new one.
    if ((action == MenuAction_Select || action == MenuAction_Cancel)
        && param1 >= 1 && param1 <= MaxClients && g_RoundPickerMenu[param1] == menu) {
        g_RoundPickerMenu[param1] = null;

        if (action == MenuAction_Cancel) {
            AllocDebug("nades: menu of the round of client %d cancelled, reason %d", param1, param2);
            // Closed by the player, or left alone until it timed out: it does not come
            // back in this round. (A menu pushed out by another one does.)
            if (param2 == MenuCancel_Exit || param2 == MenuCancel_Timeout) {
                g_RoundPickerDismissed[param1] = true;
            }
        }
    }

    if (action == MenuAction_Select) {
        int client = param1;
        char info[4];
        menu.GetItem(param2, info, sizeof(info));
        int nade = info[1];

        if (info[0] == PICK_ROUND) {
            if (AddRoundPick(client, nade)) {
                ShowNadePicker(client, PICK_ROUND);
            }
        } else if (CanAddNade(g_NadeList[client], nade)) {
            AppendNade(g_NadeList[client], nade);
            SaveNadeSetting(client, false);
            if (strlen(g_NadeList[client]) < MAX_NADES) {
                ShowNadePicker(client, PICK_LIST);
            } else {
                ShowNadesMenu(client);
            }
        }
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowNadesMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}
