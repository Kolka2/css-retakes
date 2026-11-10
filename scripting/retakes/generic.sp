#tryinclude "manual_version.sp"
#if !defined PLUGIN_VERSION
#define PLUGIN_VERSION "0.3.4"
#endif

#define INTEGER_STRING_LENGTH 20 // max number of digits a 64-bit integer can use up as a string
                                 // this is for converting ints to strings when setting menu values/cookies

#include <sdktools>
#include <cstrike>
#include <clientprefs>

// Цвета чата CS:S: \x01 - обычный, \x04 - зелёный, \x05 - оливковый, \x07RRGGBB - произвольный.
// Имена тегов те же, что в CS:GO-версии, поэтому файлы переводов менять не нужно.
// CSS-VERIFY: чат CS:S понимает \x07RRGGBB в сообщениях PrintToChat (нет "квадратиков", теги раскрашены).
char g_ColorNames[][] = {"{NORMAL}", "{DARK_RED}", "{PURPLE}", "{GREEN}", "{MOSS_GREEN}", "{LIGHT_GREEN}", "{LIGHT_RED}", "{GRAY}", "{ORANGE}", "{LIGHT_BLUE}", "{DARK_BLUE}"};
char g_ColorCodes[][] = {"\x01", "\x07CC0000", "\x07B980EF", "\x04", "\x05", "\x0799FF99", "\x07FF4040", "\x07CCCCCC", "\x07FFA500", "\x0799CCFF", "\x074D7AFF"};

/**
 * Removes (and destroys) every weapon the client is carrying.
 * Замена Client_RemoveAllWeapons из smlib.
 */
stock void RemoveAllWeapons(int client) {
    if (!HasEntProp(client, Prop_Send, "m_hMyWeapons")) {
        return;
    }

    int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < size; i++) {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon > MaxClients && IsValidEntity(weapon)) {
            RemovePlayerItem(client, weapon);
            AcceptEntityInput(weapon, "Kill");
        }
    }
}

/**
 * Sets the armor value of a client.
 * Замена Client_SetArmor из smlib.
 */
stock void SetClientArmor(int client, int value) {
    if (HasEntProp(client, Prop_Send, "m_ArmorValue")) {
        SetEntProp(client, Prop_Send, "m_ArmorValue", value);
    }
}

/**
 * Returns if the 2 players should be fighting each other.
 * Returns false on friendly fire/suicides.
 */
stock bool HelpfulAttack(int attacker, int victim) {
    if (!IsValidClient(attacker) || !IsValidClient(victim)) {
        return false;
    }
    int ateam = GetClientTeam(attacker); // Get attacker's team
    int vteam = GetClientTeam(victim);   // Get the victim's team
    return ateam != vteam && attacker != victim;
}

/**
 * Returns the Human counts of the T & CT Teams.
 * Use this function for optimization if you have to get the counts of both teams,
 */
stock void GetTeamsClientCounts(int &tHumanCount, int &ctHumanCount) {
    for (int client = 1; client <= MaxClients; client++) {
        if (IsClientConnected(client) && IsClientInGame(client)) {
            if (GetClientTeam(client) == CS_TEAM_T)
                tHumanCount++;

            else if (GetClientTeam(client) == CS_TEAM_CT)
                ctHumanCount++;
        }
    }
}

/**
 * Returns the number of players currently on an active team (T/CT).
 */
stock int GetActivePlayerCount() {
    int count = 0;
    for (int client = 1; client <= MaxClients; client++) {
        if (IsClientConnected(client) && IsClientInGame(client)) {
            if (GetClientTeam(client) == CS_TEAM_T)
                count++;
            else if (GetClientTeam(client) == CS_TEAM_CT)
                count++;
        }
    }
    return count;
}


/**
 * Returns if a player is on an active/player team.
 */
stock bool IsOnTeam(int client) {
    int team = GetClientTeam(client);
    return (team == CS_TEAM_CT) || (team == CS_TEAM_T);
}

stock bool IsConnected(int client) {
    return client > 0 && client <= MaxClients && IsClientConnected(client) && !IsFakeClient(client);
}

/**
 * Function to identify if a client is valid and in game.
 */
stock bool IsValidClient(int client) {
    if (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client))
        return true;
    return false;
}

/**
 * Function to identify if a client is valid and in game.
 */
stock bool IsPlayer(int client) {
    return IsValidClient(client) && !IsFakeClient(client);
}

stock void AddMenuOption(Menu menu, const char[] info, const char[] display, any ...) {
    char formattedDisplay[128];
    VFormat(formattedDisplay, sizeof(formattedDisplay), display, 4);
    menu.AddItem(info, formattedDisplay);
}

stock void AddMenuOptionDisabled(Menu menu, const char[] info, const char[] display, any ...) {
    char formattedDisplay[128];
    VFormat(formattedDisplay, sizeof(formattedDisplay), display, 4);
    menu.AddItem(info, formattedDisplay, ITEMDRAW_DISABLED);
}

/**
 * Adds an integer to a menu as a string choice.
 */
stock void AddMenuInt(Menu menu, int value, const char[] display) {
    char buffer[INTEGER_STRING_LENGTH];
    IntToString(value, buffer, sizeof(buffer));
    menu.AddItem(buffer, display);
}

/**
 * Adds an integer to a menu as a string choice with the integer as the display.
 */
stock void AddMenuInt2(Menu menu, int value) {
    char buffer[INTEGER_STRING_LENGTH];
    IntToString(value, buffer, sizeof(buffer));
    menu.AddItem(buffer, buffer);
}

/**
 * Gets an integer to a menu from a string choice.
 */
stock int GetMenuInt(Menu menu, int param2) {
    char choice[INTEGER_STRING_LENGTH];
    menu.GetItem(param2, choice, sizeof(choice));
    return StringToInt(choice);
}

/**
 * Adds a boolean to a menu as a string choice.
 */
stock void AddMenuBool(Menu menu, bool value, const char[] display) {
    int convertedInt = value ? 1 : 0;
    AddMenuInt(menu, convertedInt, display);
}

/**
 * Gets a boolean to a menu from a string choice.
 */
stock bool GetMenuBool(Menu menu, int param2) {
    return GetMenuInt(menu, param2) != 0;
}

/**
 * Returns a random index from an array.
 */
stock int RandomIndex(ArrayList array) {
    int len = array.Length;
    if (len == 0)
        ThrowError("Can't get random index from empty array");
    return GetRandomInt(0, len - 1);
}

/**
 * Returns a random element from an array.
 */
stock int RandomElement(ArrayList array) {
    return array.Get(RandomIndex(array));
}

/**
 * Returns a randomly-created boolean.
 */
stock bool GetRandomBool() {
    return GetRandomInt(0, 1) == 0;
}

/**
 * Sets a cookie to an integer value by converting it to a string.
 */
stock void SetCookieInt(int client, Handle cookie, int value) {
    char buffer[INTEGER_STRING_LENGTH];
    IntToString(value, buffer, sizeof(buffer));
    SetClientCookie(client, cookie, buffer);
}

/**
 * Fetches the value of a cookie that is an integer.
 */
stock int GetCookieInt(int client, Handle cookie) {
    char buffer[INTEGER_STRING_LENGTH];
    GetClientCookie(client, cookie, buffer, sizeof(buffer));
    return StringToInt(buffer);
}

/**
 * Sets a cookie to a boolean value.
 */
stock void SetCookieBool(int client, Handle cookie, bool value) {
    int convertedInt = value ? 1 : 0;
    SetCookieInt(client, cookie, convertedInt);
}

/**
 * Gets a cookie that represents a boolean.
 */
stock bool GetCookieBool(int client, Handle cookie) {
    return GetCookieInt(client, cookie) != 0;
}

stock bool Chance(float p) {
    float f = GetRandomFloat();
    return f < p;
}

/**
 * Fills a buffer with the current map name,
 * with any directory information removed.
 * Example: de_dust2 instead of workshop/125351616/de_dust2
 */
stock void GetCleanMapName(char[] buffer, int size) {
    char mapName[PLATFORM_MAX_PATH+1];
    GetCurrentMap(mapName, sizeof(mapName));
    int last_slash = 0;
    int len = strlen(mapName);
    for (int i = 0;  i < len; i++) {
        if (mapName[i] == '/')
            last_slash = i + 1;
    }
    strcopy(buffer, size, mapName[last_slash]);
}

/**
 * Applies colorized characters across a string to replace color tags.
 * With strip=true the tags are simply removed (for the server console).
 */
stock void Colorize(char[] msg, int size, bool strip=false) {
    for (int i = 0; i < sizeof(g_ColorNames); i ++) {
        if (strip) {
            ReplaceString(msg, size, g_ColorNames[i], "");
        } else {
            ReplaceString(msg, size, g_ColorNames[i], g_ColorCodes[i]);
        }
    }
}
