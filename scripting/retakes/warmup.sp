// Своя разминка и "свободный режим" редактора. Подключается только из retakes.sp.
//
// В CS:S нет mp_warmup_* и m_bWarmupPeriod, поэтому разминку ведёт сам плагин.
// Файл состоит из двух частей:
//
//  1. Разминка. Всё её состояние (флаг, отсчёт, сохранённый mp_buytime) объявлено static
//     и снаружи недоступно. Интерфейс - три функции:
//       Warmup_Start(seconds)  - начать разминку;
//       Warmup_End()           - закончить её (без рестарта игры, это делает GoLive);
//       Warmup_IsActive()      - идёт ли разминка.
//     Весь остальной код плагина узнаёт о разминке только через натив Retakes_InWarmup().
//     Warmup_OnMapStart() - служебный сброс состояния при смене карты.
//
//  2. Свободный режим: респаун после смерти и раунд, который не заканчивается.
//     Им пользуются и разминка, и редактор спавнов (g_EditMode).

#define FREEPLAY_ROUND_TIME 3600     // запас времени раунда в свободном режиме, секунды
#define FREEPLAY_RESPAWN_DELAY 1.5   // через сколько секунд после смерти респаунить
#define MAX_ROUND_TIME 30000         // m_iRoundTime передаётся по сети 16 битами

#define WARMUP_MONEY 16000           // деньги в разминке (максимум CS:S)
#define WARMUP_BUYTIME 1440.0        // mp_buytime на время разминки, минуты

/***********************
 *                     *
 *      Разминка       *
 *                     *
 ***********************/

static bool g_WarmupActive;
static int g_WarmupTimeLeft;
static ConVar g_hBuyTimeCvar;
static bool g_BuyTimeSaved;
static float g_SavedBuyTime;

/**
 * Returns if the plugin-managed warmup is running.
 * Code outside of this file should use the Retakes_InWarmup() native instead.
 */
bool Warmup_IsActive() {
    return g_WarmupActive;
}

/**
 * Starts the plugin-managed warmup. A non-positive time skips the warmup.
 */
void Warmup_Start(int time) {
    if (time <= 0) {
        g_WarmupActive = false;
        return;
    }

    g_WarmupActive = true;
    g_WarmupTimeLeft = time;

    // Тем, кто уже в игре (разминка запущена командой), деньги выдаём сразу.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && IsOnTeam(i)) {
            SetClientMoney(i, WARMUP_MONEY);
        }
    }
    DebugLog("warmup: started, %d seconds", time);
}

/**
 * Ends the warmup and puts back what it changed. Does not restart the game: see GoLive().
 */
void Warmup_End() {
    g_WarmupActive = false;
    RestoreBuyTime();
}

/**
 * Forgets the warmup state on a map change. Unlike Warmup_End() this leaves mp_buytime
 * alone: retakes_game.cfg is about to be executed and sets it anyway.
 */
void Warmup_OnMapStart() {
    g_WarmupActive = false;
    g_BuyTimeSaved = false;
}

/**
 * Keeps the buy time open during the warmup: the warmup is one endless round, and with
 * the normal mp_buytime buying would stop a few seconds after it began.
 * Called every second, because retakes_game.cfg sets mp_buytime after the warmup has started.
 */
static void ExtendWarmupBuyTime() {
    if (g_hBuyTimeCvar == null) {
        // CSS-VERIFY: mp_buytime (в минутах) принимает большое значение, и с ним в разминке
        // можно закупаться в зоне закупки всё время, а не только первые секунды раунда.
        g_hBuyTimeCvar = FindConVar("mp_buytime");
        if (g_hBuyTimeCvar == null) {
            return;
        }
    }

    if (g_hBuyTimeCvar.FloatValue < WARMUP_BUYTIME) {
        if (!g_BuyTimeSaved) {
            g_BuyTimeSaved = true;
            g_SavedBuyTime = g_hBuyTimeCvar.FloatValue;
        }
        g_hBuyTimeCvar.SetFloat(WARMUP_BUYTIME);
    }
}

/**
 * Puts mp_buytime back after the warmup.
 */
static void RestoreBuyTime() {
    if (g_BuyTimeSaved && g_hBuyTimeCvar != null) {
        g_hBuyTimeCvar.SetFloat(g_SavedBuyTime);
    }
    g_BuyTimeSaved = false;
}

static int GetHumanCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i)) {
            count++;
        }
    }
    return count;
}

/**
 * One second of the warmup: keeps buying open and drives the countdown.
 * Called by Timer_FreePlay while the warmup is active and the editor is closed.
 */
static void Warmup_Tick() {
    ExtendWarmupBuyTime();

    if (GetHumanCount() == 0) {
        // Без людей разминка не заканчивается: первый зашедший получает её целиком.
        g_WarmupTimeLeft = g_WarmupTimeCvar.IntValue;
        return;
    }

    if (g_WarmupTimeLeft <= 0) {
        GoLive();
        return;
    }

    // Если на сервере остался старый файл переводов без этой фразы, показываем английский текст,
    // а не сыплем ошибками каждую секунду.
    bool translated = TranslationPhraseExists("WarmupTimeLeft");
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsPlayer(i)) {
            continue;
        }
        if (translated) {
            PrintHintText(i, "%t", "WarmupTimeLeft", g_WarmupTimeLeft);
        } else {
            PrintHintText(i, "Warmup: %d sec", g_WarmupTimeLeft);
        }
    }
    g_WarmupTimeLeft--;
}

/***********************
 *                     *
 *   Свободный режим   *
 *                     *
 ***********************/

float g_LastDeathTime[MAXPLAYERS+1];
bool g_RoundTimePropMissingLogged;

/**
 * Returns if the plugin is in a "free play" state: warmup or the spawn editor.
 * Players respawn after dying and the round never ends.
 */
stock bool InFreePlay() {
    return Retakes_InWarmup() || g_EditMode;
}

/**
 * Sets the length of the current round, in seconds.
 * Returns false if the game doesn't have the property.
 */
stock bool SetRoundTime(int seconds) {
    // CSS-VERIFY: у CCSGameRulesProxy есть m_iRoundTime, и его изменение посреди раунда
    // меняет таймер на HUD и момент окончания раунда.
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

/**
 * Pushes the end of the round far away, so the round timer never runs out in free play.
 */
stock void ExtendFreePlayRound() {
    int elapsed = 0;
    // CSS-VERIFY: у CCSGameRulesProxy есть m_fRoundStartTime (время конца фризтайма).
    if (FindSendPropInfo("CCSGameRulesProxy", "m_fRoundStartTime") != -1) {
        elapsed = RoundToFloor(GetGameTime() - GameRules_GetPropFloat("m_fRoundStartTime"));
        if (elapsed < 0) {
            elapsed = 0;
        }
    }
    SetRoundTime(elapsed + FREEPLAY_ROUND_TIME);
}

/**
 * Ends the warmup/edit mode and restarts the game, the first retake follows the restart.
 */
public void GoLive() {
    DebugLog("warmup: going live (warmup: %d, edit mode: %d), restarting the game", Retakes_InWarmup(), g_EditMode);
    Warmup_End();
    g_EditMode = false;
    // В редакторе ботов нет: возвращаем их сразу, чтобы они успели зайти до рестарта.
    UpdateBotQuota(false);
    // Раунд после рестарта подготовит Event_RoundStart: round_end при mp_restartgame может не прийти.
    g_PreparePending = false;
    g_RoundPrepared = false;
    ServerCommand("mp_restartgame 1");
}

/**
 * Returns if a player picked a player class (model). In CS:S a player that
 * joined a team cannot spawn until the class menu is answered.
 */
stock bool HasPickedClass(int client) {
    // CSS-VERIFY: у CCSPlayer есть m_iClass; 0 - класс ещё не выбран.
    if (!HasEntProp(client, Prop_Send, "m_iClass")) {
        return true;
    }
    return GetEntProp(client, Prop_Send, "m_iClass") != 0;
}

/**
 * Respawns the dead players in the free play mode. This covers both the players that
 * were killed and the ones that joined a team too late to be spawned by the game.
 */
static void RespawnDeadPlayers() {
    float now = GetGameTime();
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClient(i) || !IsOnTeam(i) || IsPlayerAlive(i)) {
            continue;
        }
        if (!HasPickedClass(i) || now - g_LastDeathTime[i] < FREEPLAY_RESPAWN_DELAY) {
            continue;
        }
        CS_RespawnPlayer(i);
    }
}

/**
 * Runs every second for the whole map: drives the warmup countdown and the free play respawns.
 */
public Action Timer_FreePlay(Handle timer) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    OnSecondTick();

    if (!InFreePlay()) {
        return Plugin_Continue;
    }

    ExtendFreePlayRound();
    RespawnDeadPlayers();

    if (g_EditMode) {
        // В редакторе отсчёт разминки стоит на паузе.
        return Plugin_Continue;
    }

    // Свободный режим без редактора - это разминка.
    Warmup_Tick();
    return Plugin_Continue;
}

/**
 * Blocks the end of the round in free play, so the map is never reset under the players.
 */
public Action CS_OnTerminateRound(float &delay, CSRoundEndReason &reason) {
    if (!g_Enabled || !InFreePlay()) {
        return Plugin_Continue;
    }

    // "Game Commencing" пропускаем: это штатный первый рестарт игры, он сбрасывает счёт.
    if (reason == CSRoundEnd_GameStart) {
        return Plugin_Continue;
    }

    // CSS-VERIFY: Plugin_Handled здесь действительно отменяет конец раунда в CS:S
    // (все убиты / вышло время), и игра после этого не "зависает".
    return Plugin_Handled;
}
