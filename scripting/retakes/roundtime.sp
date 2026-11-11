// Round clock helper. Included only from retakes.sp.

#define MAX_ROUND_TIME 30000   // m_iRoundTime is networked with 16 bits

bool g_RoundTimePropMissingLogged;

/**
 * Sets the length of the current round, in seconds.
 * Returns false if the game doesn't have the property.
 */
stock bool SetRoundTime(int seconds) {
    // CSS-VERIFY: CCSGameRulesProxy has m_iRoundTime and changing it mid-round moves both
    // the HUD timer and the moment the round ends.
    if (FindSendPropInfo("CCSGameRulesProxy", "m_iRoundTime") == -1) {
        if (!g_RoundTimePropMissingLogged) {
            g_RoundTimePropMissingLogged = true;
            LogError("CCSGameRulesProxy::m_iRoundTime was not found, the round time cannot be changed");
        }
        return false;
    }

    if (seconds < 1) {
        seconds = 1;
    } else if (seconds > MAX_ROUND_TIME) {
        seconds = MAX_ROUND_TIME;
    }

    GameRules_SetProp("m_iRoundTime", seconds, 4, 0, true);
    return true;
}
