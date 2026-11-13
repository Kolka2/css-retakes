// Debug log of the plugin's decisions (sm_retakes_debug 1), written to
// addons/sourcemod/logs/retakes_debug.log. Included only from retakes.sp.

/**
 * Returns if the debug log is enabled.
 */
bool DebugEnabled() {
    return g_hDebug != null && g_hDebug.IntValue != 0;
}

/**
 * Writes a line to logs/retakes_debug.log if sm_retakes_debug is set.
 */
void DebugLog(const char[] format, any ...) {
    if (!DebugEnabled()) {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "logs/retakes_debug.log");
    LogToFile(path, "%s", buffer);
}
