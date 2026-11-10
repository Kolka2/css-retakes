// Функции смены команд. Подключается только из retakes.sp:
// использует g_PluginTeamSwitch, которого нет в аддонах.

#define CSS_FIRST_T_CLASS 1
#define CSS_LAST_T_CLASS 4
#define CSS_FIRST_CT_CLASS 5
#define CSS_LAST_CT_CLASS 8

/**
 * Makes sure the client has a player class (model) that belongs to the team.
 * In CS:S a player without a valid class is not respawned on round restart, and a
 * player moved from spectators by the plugin never saw the class menu.
 */
static void EnsureClientClass(int client, int team) {
    // CSS-VERIFY: у CCSPlayer есть m_iClass (1-4 - классы T, 5-8 - классы CT), и после CS_SwitchTeam
    // из наблюдателей игрок с выставленным классом спаунится при рестарте раунда без меню выбора модели.
    if (!HasEntProp(client, Prop_Send, "m_iClass")) {
        return;
    }

    int class = GetEntProp(client, Prop_Send, "m_iClass");
    if (team == CS_TEAM_T) {
        if (class < CSS_FIRST_T_CLASS || class > CSS_LAST_T_CLASS) {
            SetEntProp(client, Prop_Send, "m_iClass", GetRandomInt(CSS_FIRST_T_CLASS, CSS_LAST_T_CLASS));
        }
    } else if (team == CS_TEAM_CT) {
        if (class < CSS_FIRST_CT_CLASS || class > CSS_LAST_CT_CLASS) {
            SetEntProp(client, Prop_Send, "m_iClass", GetRandomInt(CSS_FIRST_CT_CLASS, CSS_LAST_CT_CLASS));
        }
    }
}

/**
 * Switches a player to a new team.
 */
stock void SwitchPlayerTeam(int client, int team) {
    if (GetClientTeam(client) == team)
        return;

    g_PluginTeamSwitch[client] = true;
    if (team > CS_TEAM_SPECTATOR) {
        CS_SwitchTeam(client, team);
        EnsureClientClass(client, team);
        CS_UpdateClientModel(client);
    } else {
        ChangeClientTeam(client, team);
    }
    g_PluginTeamSwitch[client] = false;
}
