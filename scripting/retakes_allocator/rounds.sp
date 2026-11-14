// Round types: what kind of round is played and what a player gets in it.
// Included only from retakes_allocator.sp.

// CS:S buy menu prices of the equipment.
#define PRICE_KEVLAR 650
#define PRICE_HELMET 350 // on top of the kevlar
#define PRICE_KIT 200

// Where the primary weapon of a round type comes from. The order must match g_PrimaryNames.
enum PrimaryPolicy {
    Primary_None = 0, // no primary weapon
    Primary_Random,   // a random one the budget allows
    Primary_Rifle,    // the rifle the player chose; the AWP for one player that asked for it
};

char g_PrimaryNames[][] = { "none", "random", "rifle" };

// Columns of g_RoundTypes.
#define TYPE_TOKEN 0     // the name used in sm_retakes_alloc_rounds; the phrase is "RoundType_<token>"
#define TYPE_BUDGET 1    // money a player "spends" on the weapons, the armor and the kit
#define TYPE_PRIMARY 2   // one of g_PrimaryNames
#define TYPE_NADES_MIN 3 // grenades per player, from ...
#define TYPE_NADES_MAX 4 // ... to
#define TYPE_KIT_CHANCE 5 // percent of the CTs that try to buy a defuse kit

// One row per round type. A loadout is bought by BuildLoadout() within the budget:
//   pistol - kevlar, or a better pistol, or a kit with something cheap;
//   bonus  - a better pistol and the kevlar, the rest as the money allows;
//   force  - a rifle with little or no armor, or something cheaper with armor;
//   buy    - the budget covers everything.
char g_RoundTypes[][][] = {
    { "pistol", "800",   "none",   "0", "1", "50" },
    { "bonus",  "1700",  "none",   "1", "1", "50" },
    { "force",  "3300",  "random", "0", "1", "50" },
    { "buy",    "16000", "rifle",  "1", "2", "100" },
};

// The numeric columns of g_RoundTypes, filled by ParseRoundTypes().
int g_TypeBudget[sizeof(g_RoundTypes)];
PrimaryPolicy g_TypePrimary[sizeof(g_RoundTypes)];
int g_TypeNadesMin[sizeof(g_RoundTypes)];
int g_TypeNadesMax[sizeof(g_RoundTypes)];
int g_TypeKitChance[sizeof(g_RoundTypes)];

// sm_retakes_alloc_rounds, parsed: the round types in order and how many rounds each lasts.
#define MAX_CYCLE_ENTRIES 16
int g_CycleType[MAX_CYCLE_ENTRIES];
int g_CycleRounds[MAX_CYCLE_ENTRIES];
int g_CycleEntries;
int g_CycleLength; // the sum of g_CycleRounds

// The round the loadouts were last built for.
int g_RoundType;
int g_RoundNumber;  // 1-based number of the round inside its cycle entry
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
 * Returns if any round type of the cycle takes its primary weapon from the given source,
 * i.e. if the players have something to set up for it.
 */
bool CycleHasPrimary(PrimaryPolicy policy) {
    for (int i = 0; i < g_CycleEntries; i++) {
        if (g_TypePrimary[g_CycleType[i]] == policy) {
            return true;
        }
    }
    return false;
}

/**
 * Decides the type of the round that is being prepared.
 *
 * The rounds go in a circle. The position in the circle comes from the number of rounds
 * retakes has played, which starts over when the game restarts or the map changes, so
 * the allocator keeps no counter of its own.
 */
static void PickRoundType() {
    int position = Retakes_GetRetakeRoundsPlayed() % g_CycleLength;
    for (int i = 0; i < g_CycleEntries; i++) {
        if (position < g_CycleRounds[i]) {
            g_RoundType = g_CycleType[i];
            g_RoundNumber = position + 1;
            g_RoundsOfType = g_CycleRounds[i];
            return;
        }
        position -= g_CycleRounds[i];
    }
}

/**
 * Sets the loadout of one player for a round of the given type.
 *
 * The player "buys" within the budget of the round type: first the primary weapon, then
 * the kevlar, a better pistol (only when there is no primary weapon) and the defuse kit
 * (not every CT wants one in a cheap round) in a random order, and the helmet with what
 * is left. The grenades do not come out of
 * the budget: their number is set by the round type (see nades.sp).
 *
 * awpLeft tells if the team may still get its AWP and is cleared when this player takes it.
 */
static void BuildLoadout(int client, bool ct, int type, bool &awpLeft) {
    int side = SideIndex(ct);
    int money = g_TypeBudget[type];

    int primary = -1;
    switch (g_TypePrimary[type]) {
        case Primary_Random: {
            primary = RandomWeapon(CAT_ANY_PRIMARY, ct, money);
        }
        case Primary_Rifle: {
            if (awpLeft && g_AwpChoice[client]) {
                primary = g_Awp;
                awpLeft = false;
            } else {
                primary = g_Rifle[client][side];
            }
        }
    }
    if (primary != -1) {
        money -= g_WeaponPrice[primary];
    }

    int pistol = g_DefaultPistol[side];
    bool armor = false;
    bool kit = false;

    int extras[NUM_EXTRAS] = { EXTRA_ARMOR, EXTRA_PISTOL, EXTRA_KIT };
    ShuffleInts(extras, NUM_EXTRAS);
    for (int i = 0; i < NUM_EXTRAS; i++) {
        switch (extras[i]) {
            case EXTRA_ARMOR: {
                if (money >= PRICE_KEVLAR) {
                    armor = true;
                    money -= PRICE_KEVLAR;
                }
            }
            case EXTRA_PISTOL: {
                int better = (primary == -1) ? RandomWeapon(CAT_PISTOL, ct, money) : -1;
                if (better != -1) {
                    pistol = better;
                    money -= g_WeaponPrice[better];
                }
            }
            case EXTRA_KIT: {
                if (ct && money >= PRICE_KIT && GetRandomInt(1, 100) <= g_TypeKitChance[type]) {
                    kit = true;
                    money -= PRICE_KIT;
                }
            }
        }
    }
    bool helmet = armor && money >= PRICE_HELMET;

    char primaryClass[WEAPON_STRING_LENGTH];
    char pistolClass[WEAPON_STRING_LENGTH];
    char nades[NADE_STRING_LENGTH];
    GetWeaponClass(primary, primaryClass, sizeof(primaryClass));
    GetWeaponClass(pistol, pistolClass, sizeof(pistolClass));
    PickNades(type, nades);

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
    AllocateTeam(tPlayers, false);
    AllocateTeam(ctPlayers, true);
}
