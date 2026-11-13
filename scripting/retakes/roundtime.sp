// Round clock helper. Included only from retakes.sp.

#define MAX_ROUND_TIME 30000   // m_iRoundTime is networked with 16 bits

/**
 * Sets the length of the current round, in seconds. Changing m_iRoundTime mid-round
 * moves both the HUD timer and the moment the round ends (checked on a live server).
 */
void SetRoundTime(int seconds) {
    if (seconds < 1) {
        seconds = 1;
    } else if (seconds > MAX_ROUND_TIME) {
        seconds = MAX_ROUND_TIME;
    }

    GameRules_SetProp("m_iRoundTime", seconds, 4, 0, true);
}
