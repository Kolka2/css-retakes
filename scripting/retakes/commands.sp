// Player and admin commands that do not belong to the spawn editor.
// Included only from retakes.sp.

public Action Command_ScrambleTeams(int client, int args) {
    if (g_Enabled) {
        g_ScrambleSignal = true;
        Retakes_MessageToAll("%t", "AdminScrambleTeams", client);
    }

    return Plugin_Continue;
}

/**
 * Asks the weapon allocator plugins to show their menu to a client.
 */
static void CallGunsForward(int client) {
    Call_StartForward(g_hOnGunsCommand);
    Call_PushCell(client);
    Call_Finish();
}

/**
 * Tells a player about the !guns menu. Shown once per connection, when the player first
 * gets into the game (first spawn or the waiting queue), and only if a weapon allocator
 * is loaded: without one the command does nothing.
 * The original plugin has no such hint, it was added at the owner's request.
 */
void ShowGunsHint(int client) {
    if (g_GunsHintShown[client] || !IsPlayer(client) || g_EditMode) {
        return;
    }
    g_GunsHintShown[client] = true;

    // An allocator is loaded if somebody listens to the Retakes_OnGunsCommand forward.
    if (GetForwardFunctionCount(g_hOnGunsCommand) == 0) {
        return;
    }

    if (TranslationPhraseExists("GunsHint")) {
        Retakes_Message(client, "%t", "GunsHint");
    } else {
        Retakes_Message(client, "Type {GREEN}!guns{NORMAL} in chat to choose your weapons.");
    }
}

public Action Command_Guns(int client, int args) {
    if (g_Enabled) {
        CallGunsForward(client);
    }
    return Plugin_Handled;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] args) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    static char gunsChatCommands[][] = { "gun", "guns", ".gun", ".guns", "!gun", "gnus" };
    for (int i = 0; i < sizeof(gunsChatCommands); i++) {
        if (strcmp(args[0], gunsChatCommands[i], false) == 0) {
            CallGunsForward(client);
            break;
        }
    }

    return Plugin_Continue;
}

/**
 * sm_retakes_warmup [seconds]: starts a warmup without changing the map and resets the
 * retakes progress. Without an argument sm_retakes_warmuptime is used; 0 ends the warmup.
 * The warmup itself is run by the warmup plugin.
 */
public Action Command_Warmup(int client, int args) {
    if (!g_Enabled) {
        ReplyToCommand(client, "[Retakes] The plugin is disabled.");
        return Plugin_Handled;
    }

    if (!WarmupAvailable()) {
        ReplyToCommand(client, "[Retakes] The warmup plugin (warmup.smx) is not loaded.");
        return Plugin_Handled;
    }

    if (g_EditMode) {
        ReplyToCommand(client, "[Retakes] Exit the spawn editor first (\"Exit edit mode\" in the !edit menu).");
        return Plugin_Handled;
    }

    int time = g_WarmupTimeCvar.IntValue;
    if (args >= 1) {
        char buffer[16];
        GetCmdArg(1, buffer, sizeof(buffer));
        time = StringToInt(buffer);
    }

    if (time <= 0) {
        if (Retakes_InWarmup()) {
            Retakes_MessageToAll("The warmup was ended by an admin.");
            // Warmup_OnEnd takes it from here and starts the first retake.
            Warmup_End();
        } else {
            ReplyToCommand(client, "[Retakes] There is no warmup to end. Usage: sm_retakes_warmup [seconds]");
        }
        return Plugin_Handled;
    }

    DebugLog("warmup: restarted by %L", client);
    ResetRetakesProgress();
    if (!Warmup_Start(time)) {
        ReplyToCommand(client, "[Retakes] The warmup plugin refused to start a warmup (sm_warmup_enabled 0?).");
        return Plugin_Handled;
    }
    UpdateBotQuota(false);
    Retakes_MessageToAll("Warmup for {GREEN}%d{NORMAL} seconds. Pick any team.", time);
    return Plugin_Handled;
}
