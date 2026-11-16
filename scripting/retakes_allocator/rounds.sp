// Round types: what kind of round is played and what a player gets in it.
// Included only from retakes_allocator.sp.

// CS:S buy menu prices of the equipment.
#define PRICE_KEVLAR 650
#define PRICE_HELMET 350 // on top of the kevlar
#define PRICE_KIT 200

// Columns of g_RoundTypes.
#define TYPE_TOKEN 0     // the name used in sm_retakes_alloc_rounds; the phrase is "RoundType_<token>"
#define TYPE_BUDGET 1    // money a player "spends" on the weapons, the armor and the kit
#define TYPE_PRIMARY 2   // one of g_PrimaryNames (see PrimaryPolicy in choices.sp)
#define TYPE_NADES_MIN 3 // grenades per player, from ...
#define TYPE_NADES_MAX 4 // ... to
#define TYPE_KIT_CHANCE 5 // percent of the CTs that try to buy a defuse kit

// One row per round type. A loadout is bought by BuildLoadout() within the budget:
//   pistol - kevlar, or a better pistol, or a kit with something cheap;
//   bonus  - a better pistol and the kevlar, the rest as the money allows;
//   force  - a rifle with little or no armor, or something cheaper with armor;
//   buy    - the budget covers everything;
//   free   - the same, with any weapon of the game ("chaos").
char g_RoundTypes[][][] = {
    { "pistol", "800",   "none",   "0", "1", "50" },
    { "bonus",  "1700",  "none",   "1", "1", "50" },
    { "force",  "3300",  "random", "0", "1", "50" },
    { "buy",    "16000", "rifle",  "1", "2", "100" },
    { "free",   "16000", "free",   "0", "4", "100" },
};

// The numeric columns of g_RoundTypes, filled by ParseRoundTypes().
int g_TypeBudget[sizeof(g_RoundTypes)];
PrimaryPolicy g_TypePrimary[sizeof(g_RoundTypes)];
int g_TypeNadesMin[sizeof(g_RoundTypes)];
int g_TypeNadesMax[sizeof(g_RoundTypes)];
int g_TypeKitChance[sizeof(g_RoundTypes)];
// sm_retakes_alloc_random_types, parsed: the weapons of the type are always random.
bool g_TypeForcedRandom[sizeof(g_RoundTypes)];

// sm_retakes_alloc_rounds, parsed: the round types in order and how many rounds each lasts.
#define MAX_CYCLE_ENTRIES 16
int g_CycleType[MAX_CYCLE_ENTRIES];
int g_CycleRounds[MAX_CYCLE_ENTRIES];
int g_CycleEntries;
int g_CycleLength; // the sum of g_CycleRounds

// The round the loadouts were last built for.
int g_RoundType;
int g_RoundNumber;  // 1-based number of the round inside its cycle entry; 0 in the random order
int g_RoundsOfType; // how many rounds the cycle entry lasts

// The things a player buys besides the primary weapon, in a random order.
#define EXTRA_ARMOR 0
#define EXTRA_PISTOL 1
#define EXTRA_KIT 2
#define NUM_EXTRAS 3

/**
 * Fills the numeric columns of the round type table. Called once, when the plugin starts.
 */
void ParseRoundTypes() {
    for (int i = 0; i < sizeof(g_RoundTypes); i++) {
        g_TypeBudget[i] = StringToInt(g_RoundTypes[i][TYPE_BUDGET]);
        g_TypeNadesMin[i] = StringToInt(g_RoundTypes[i][TYPE_NADES_MIN]);
        g_TypeNadesMax[i] = StringToInt(g_RoundTypes[i][TYPE_NADES_MAX]);
        g_TypeKitChance[i] = StringToInt(g_RoundTypes[i][TYPE_KIT_CHANCE]);

        int policy = -1;
        for (int p = 0; p < sizeof(g_PrimaryNames); p++) {
            if (StrEqual(g_RoundTypes[i][TYPE_PRIMARY], g_PrimaryNames[p])) {
                policy = p;
            }
        }
        if (policy == -1) {
            SetFailState("Round type \"%s\" has an unknown primary weapon policy \"%s\"",
                         g_RoundTypes[i][TYPE_TOKEN], g_RoundTypes[i][TYPE_PRIMARY]);
        }
        g_TypePrimary[i] = view_as<PrimaryPolicy>(policy);
    }

    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        g_SlotType[slot] = FindRoundType(g_SlotTypeTokens[slot]);
        if (g_SlotType[slot] == -1) {
            SetFailState("Choice slot %d belongs to an unknown round type \"%s\"", slot, g_SlotTypeTokens[slot]);
        }
        g_SlotMaxPrice[slot] = g_TypeBudget[g_SlotType[slot]];
    }
}

/**
 * Parses sm_retakes_alloc_random_types: the round types, separated by commas, in which
 * the weapons the players chose are ignored. Unknown names are logged and skipped.
 */
void ParseRandomTypes(const char[] value) {
    for (int i = 0; i < sizeof(g_RoundTypes); i++) {
        g_TypeForcedRandom[i] = false;
    }

    char tokens[sizeof(g_RoundTypes) * 2][24];
    int count = ExplodeString(value, ",", tokens, sizeof(tokens), sizeof(tokens[]));
    for (int i = 0; i < count; i++) {
        TrimString(tokens[i]);
        if (tokens[i][0] == '\0') {
            continue;
        }
        int type = FindRoundType(tokens[i]);
        if (type == -1) {
            LogError("sm_retakes_alloc_random_types: \"%s\" is not a round type, skipped", tokens[i]);
        } else {
            g_TypeForcedRandom[type] = true;
        }
    }
}

static int FindRoundType(const char[] token) {
    for (int i = 0; i < sizeof(g_RoundTypes); i++) {
        if (StrEqual(token, g_RoundTypes[i][TYPE_TOKEN], false)) {
            return i;
        }
    }
    return -1;
}

static void AddCycleEntry(int type, int rounds) {
    g_CycleType[g_CycleEntries] = type;
    g_CycleRounds[g_CycleEntries] = rounds;
    g_CycleEntries++;
    g_CycleLength += rounds;
}

/**
 * Parses the value of sm_retakes_alloc_rounds: "type:rounds,type:rounds,...", where
 * ":rounds" may be left out (1 round). Entries that make no sense are logged and skipped;
 * if nothing is left, every round is a buy round.
 */
void ParseRounds(const char[] value) {
    g_CycleEntries = 0;
    g_CycleLength = 0;

    char entries[MAX_CYCLE_ENTRIES][32];
    int count = ExplodeString(value, ",", entries, sizeof(entries), sizeof(entries[]));
    for (int i = 0; i < count; i++) {
        char pair[2][24];
        int fields = ExplodeString(entries[i], ":", pair, sizeof(pair), sizeof(pair[]));
        TrimString(pair[0]);

        int rounds = 1;
        if (fields >= 2) {
            TrimString(pair[1]);
            rounds = StringToInt(pair[1]);
        }

        int type = FindRoundType(pair[0]);
        if (type == -1 || rounds < 1) {
            LogError("sm_retakes_alloc_rounds: \"%s\" is not \"type\" or \"type:rounds\" with a known round type, skipped",
                     entries[i]);
            continue;
        }
        AddCycleEntry(type, rounds);
    }

    if (g_CycleEntries == 0) {
        LogError("sm_retakes_alloc_rounds \"%s\" has no usable round types, every round will be a buy round", value);
        AddCycleEntry(FindRoundType("buy"), 1);
    }
}

/**
 * Returns if a round type is played, i.e. is in sm_retakes_alloc_rounds.
 */
bool CycleHasType(int type) {
    for (int i = 0; i < g_CycleEntries; i++) {
        if (g_CycleType[i] == type) {
            return true;
        }
    }
    return false;
}

/**
 * Returns the choice slot of a round type for a side (a side flag) and for the pistol or
 * the primary weapon, or -1 if the players have nothing to choose there.
 */
static int FindTypeSlot(int type, int sideFlag, bool pistol) {
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        if (g_SlotType[slot] == type && (g_SlotSides[slot] & sideFlag) != 0 && IsPistolSlot(slot) == pistol) {
            return slot;
        }
    }
    return -1;
}

/**
 * Returns the weapon a client chose in a slot, or CHOICE_RANDOM if there is no such slot,
 * the client left it at "random every round", or the type is forced to be random.
 */
static int WantedWeapon(int client, int type, int slot) {
    if (slot == -1 || g_TypeForcedRandom[type]) {
        return CHOICE_RANDOM;
    }
    return g_Choice[client][slot];
}

/**
 * What a weapon takes out of the budget: its price, or nothing for the pistol the side
 * starts with.
 */
static int WeaponCost(int weapon, int side) {
    return (weapon == g_DefaultPistol[side]) ? 0 : g_WeaponPrice[weapon];
}

/**
 * Pays for something if the money allows it. Returns if it was bought.
 */
static bool Buy(int &money, int price) {
    if (money < price) {
        return false;
    }
    money -= price;
    return true;
}

/**
 * Returns if the weapons of a slot decide how much armor the player gets, i.e. if the
 * menu should say so next to every weapon (see GetChoiceArmor).
 */
bool SlotDecidesArmor(int slot) {
    PrimaryPolicy policy = g_TypePrimary[g_SlotType[slot]];
    return policy == Primary_None || policy == Primary_Random;
}

/**
 * Tells what armor is left for a player who chose a weapon in a slot: BuildLoadout()
 * buys the chosen weapon, then the kevlar, then the helmet.
 */
void GetChoiceArmor(int slot, int weapon, bool &armor, bool &helmet) {
    int side = (g_SlotSides[slot] == SIDE_CT) ? CT_INDEX : T_INDEX;
    int money = g_SlotMaxPrice[slot] - WeaponCost(weapon, side);
    armor = Buy(money, PRICE_KEVLAR);
    helmet = armor && Buy(money, PRICE_HELMET);
}

static bool IsRandomOrder() {
    char order[16];
    g_hOrderCvar.GetString(order, sizeof(order));
    return StrEqual(order, "random", false);
}

/**
 * Decides the type of the round that is being prepared.
 *
 * Think of the cycle laid out round by round ("pistol:2,buy:3" is P P B B B); the type of
 * the round is the one at some position in it.
 *  - Order "cycle": the rounds go in a circle. The position comes from the number of
 *    rounds retakes has played, which starts over when the game restarts or the map
 *    changes, so the allocator keeps no counter of its own.
 *  - Order "random": a random position every round, with no memory of the rounds before.
 *    The round counts of the cvar work as weights (2 in 5 for the pistol round above).
 */
static void PickRoundType() {
    bool random = IsRandomOrder();
    int position = random ? GetRandomInt(0, g_CycleLength - 1)
                          : Retakes_GetRetakeRoundsPlayed() % g_CycleLength;
    for (int i = 0; i < g_CycleEntries; i++) {
        if (position < g_CycleRounds[i]) {
            g_RoundType = g_CycleType[i];
            g_RoundNumber = random ? 0 : position + 1;
            g_RoundsOfType = g_CycleRounds[i];
            return;
        }
        position -= g_CycleRounds[i];
    }
}

/**
 * Sets the loadout of one player for a round of the given type.
 *
 * The player "buys" within the budget of the round type. The grenades do not come out
 * of the budget: see nades.sp.
 *
 * The weapons come from what the player chose for the round type and the side (see the
 * slot table in choices.sp), unless there is nothing to choose, the player left it at
 * "random every round" or the type is listed in sm_retakes_alloc_random_types.
 *
 *  - Nothing chosen: first a random primary weapon (if the type has one), then the
 *    kevlar, a better pistol (only when there is no primary weapon) and the defuse kit
 *    (not every CT wants one in a cheap round) in a random order, and the helmet with
 *    what is left.
 *  - A weapon chosen: the weapon, then the kevlar, the helmet and the kit, in this
 *    order, so that the armor only depends on the weapon (the menu tells it next to
 *    every weapon).
 *
 * awpLeft tells if the team may still get its AWP and is cleared when this player takes it.
 */
static void BuildLoadout(int client, bool ct, int type, bool &awpLeft) {
    int side = SideIndex(ct);
    int sideFlag = SideFlag(ct);
    int money = g_TypeBudget[type];

    int wantPrimary = WantedWeapon(client, type, FindTypeSlot(type, sideFlag, false));
    int wantPistol = WantedWeapon(client, type, FindTypeSlot(type, sideFlag, true));
    bool chosen = (wantPrimary != CHOICE_RANDOM || wantPistol != CHOICE_RANDOM);

    int primary = -1;
    switch (g_TypePrimary[type]) {
        case Primary_Random: {
            primary = (wantPrimary != CHOICE_RANDOM) ? wantPrimary
                                                     : RandomWeapon(CAT_ANY_PRIMARY, sideFlag, money);
        }
        case Primary_Rifle: {
            if (awpLeft && g_AwpChoice[client]) {
                primary = g_Awp;
                awpLeft = false;
            } else {
                // (random: only when the type is forced to be random)
                primary = (wantPrimary != CHOICE_RANDOM) ? wantPrimary
                                                         : RandomWeapon(CAT_RIFLE, sideFlag, money);
            }
        }
        case Primary_Free: {
            primary = (wantPrimary != CHOICE_RANDOM) ? wantPrimary
                                                     : RandomWeapon(CAT_ANY_PRIMARY, SIDE_BOTH, money);
            if (wantPistol == CHOICE_RANDOM) {
                wantPistol = RandomWeapon(CAT_ANY_PISTOL, SIDE_BOTH, money);
            }
        }
    }
    if (primary != -1) {
        money -= g_WeaponPrice[primary];
    }

    int pistol = g_DefaultPistol[side];
    if (wantPistol != CHOICE_RANDOM) {
        pistol = wantPistol;
        money -= WeaponCost(pistol, side);
    }

    bool armor = false;
    bool helmet = false;
    bool kit = false;

    if (chosen) {
        armor = Buy(money, PRICE_KEVLAR);
        helmet = armor && Buy(money, PRICE_HELMET);
        kit = ct && GetRandomInt(1, 100) <= g_TypeKitChance[type] && Buy(money, PRICE_KIT);
    } else {
        int extras[NUM_EXTRAS] = { EXTRA_ARMOR, EXTRA_PISTOL, EXTRA_KIT };
        ShuffleInts(extras, NUM_EXTRAS);
        for (int i = 0; i < NUM_EXTRAS; i++) {
            switch (extras[i]) {
                case EXTRA_ARMOR: {
                    armor = Buy(money, PRICE_KEVLAR);
                }
                case EXTRA_PISTOL: {
                    int better = (primary == -1) ? RandomWeapon(CAT_PISTOL, sideFlag, money) : -1;
                    if (better != -1) {
                        pistol = better;
                        money -= g_WeaponPrice[better];
                    }
                }
                case EXTRA_KIT: {
                    kit = ct && GetRandomInt(1, 100) <= g_TypeKitChance[type] && Buy(money, PRICE_KIT);
                }
            }
        }
        helmet = armor && money >= PRICE_HELMET;
    }

    char primaryClass[WEAPON_STRING_LENGTH];
    char pistolClass[WEAPON_STRING_LENGTH];
    char nades[NADE_STRING_LENGTH];
    GetWeaponClass(primary, primaryClass, sizeof(primaryClass));
    GetWeaponClass(pistol, pistolClass, sizeof(pistolClass));
    PickNades(client, type, nades);

    Retakes_SetPlayerInfo(client, primaryClass, pistolClass, nades, 100, armor ? 100 : 0, helmet, kit);
}

static void AllocateTeam(ArrayList players, bool ct) {
    bool awpLeft = true;
    for (int i = 0; i < players.Length; i++) {
        BuildLoadout(players.Get(i), ct, g_RoundType, awpLeft);
    }
}

/**
 * Picks the type of the round and sets the loadout of everybody who plays it.
 */
void AllocateRound(ArrayList tPlayers, ArrayList ctPlayers) {
    PickRoundType();
    AllocDebug("round: loadouts are built, type \"%s\"", g_RoundTypes[g_RoundType][TYPE_TOKEN]);
    ResetRoundNades();
    AllocateTeam(tPlayers, false);
    AllocateTeam(ctPlayers, true);
    OfferRoundNades();
}
