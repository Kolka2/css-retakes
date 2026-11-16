// What the players chose in the !guns menu, and the cookies that remember it.
// Included only from retakes_allocator.sp.

// Where the primary weapon of a round type comes from. The order must match g_PrimaryNames.
enum PrimaryPolicy {
    Primary_None = 0, // no primary weapon
    Primary_Random,   // a random one the budget allows, unless the player chose one
    Primary_Rifle,    // the rifle the player chose; the AWP for one player that asked for it
    Primary_Free,     // any weapon of the game, and any pistol with it, as the player chose
};

char g_PrimaryNames[][] = { "none", "random", "rifle", "free" };

// A choice slot is one weapon setting of a player: a round type, a side and "the primary
// weapon" or "the pistol". The first two are indexed by T_INDEX / CT_INDEX (see
// DefaultChoice).
#define SLOT_T_RIFLE 0
#define SLOT_CT_RIFLE 1
#define NUM_SLOTS 10

// A slot value that is not a weapon: a random weapon every round.
// (-1 is taken: FindWeapon returns it for an unknown weapon.)
#define CHOICE_RANDOM -2
#define RANDOM_COOKIE_VALUE "random"

// The slot table, one column per array. The rifle cookies have the names
// retakes_standardallocator uses, so the players keep their choice when the server moves
// to this allocator.
char g_SlotCookieNames[NUM_SLOTS][] = {
    "retakes_triflechoice",
    "retakes_ctriflechoice",
    "retakes_alloc_freeprimary",
    "retakes_alloc_freepistol",
    "retakes_alloc_pistol_t",
    "retakes_alloc_pistol_ct",
    "retakes_alloc_bonus_t",
    "retakes_alloc_bonus_ct",
    "retakes_alloc_force_t",
    "retakes_alloc_force_ct",
};
// The round type that uses the slot (a token of g_RoundTypes). The slot is shown in the
// menu if the type is played and its weapons are not forced to be random.
char g_SlotTypeTokens[NUM_SLOTS][] = {
    "buy", "buy", "free", "free", "pistol", "pistol", "bonus", "bonus", "force", "force",
};
// Phrases "Menu<name>" (menu line) and "Select<name>" (title of the weapon list).
char g_SlotPhrases[NUM_SLOTS][] = {
    "TRifle", "CTRifle", "FreePrimary", "FreePistol",
    "TPistol", "CTPistol", "TPistol", "CTPistol", "TWeapon", "CTWeapon",
};
// The weapons a slot offers: these categories, bought by these sides, and no dearer
// than the budget of the round type (g_SlotMaxPrice).
int g_SlotCategories[NUM_SLOTS] = {
    CAT_RIFLE, CAT_RIFLE, CAT_ANY_PRIMARY, CAT_ANY_PISTOL,
    CAT_ANY_PISTOL, CAT_ANY_PISTOL, CAT_ANY_PISTOL, CAT_ANY_PISTOL, CAT_ANY_PRIMARY, CAT_ANY_PRIMARY,
};
int g_SlotSides[NUM_SLOTS] = {
    SIDE_T, SIDE_CT, SIDE_BOTH, SIDE_BOTH,
    SIDE_T, SIDE_CT, SIDE_T, SIDE_CT, SIDE_T, SIDE_CT,
};
// If the slot offers "random every round"; that is also its default value.
bool g_SlotAllowsRandom[NUM_SLOTS] = {
    false, false, true, true,
    true, true, true, true, true, true,
};
// Filled by ParseRoundTypes() from g_SlotTypeTokens: the index of the round type and
// its budget.
int g_SlotType[NUM_SLOTS];
int g_SlotMaxPrice[NUM_SLOTS];

// Indices into g_Weapons, or CHOICE_RANDOM.
int g_Choice[MAXPLAYERS+1][NUM_SLOTS];
// If the player agreed to get the AWP in buy rounds.
bool g_AwpChoice[MAXPLAYERS+1];

Handle g_hSlotCookie[NUM_SLOTS];
Handle g_hAwpCookie;

void RegisterChoiceCookies() {
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        g_hSlotCookie[slot] = RegClientCookie(g_SlotCookieNames[slot], "", CookieAccess_Private);
    }
    g_hAwpCookie = RegClientCookie("retakes_awpchoice", "", CookieAccess_Private);
}

static int DefaultChoice(int slot) {
    // only the two rifle slots have no "random every round"
    return g_SlotAllowsRandom[slot] ? CHOICE_RANDOM : g_DefaultRifle[slot];
}

/**
 * Returns if a slot is about the pistol (and not about the primary weapon).
 */
bool IsPistolSlot(int slot) {
    return (g_SlotCategories[slot] & CAT_ANY_PRIMARY) == 0;
}

/**
 * Returns if a value can be stored in a slot.
 */
bool IsValidChoice(int slot, int choice) {
    if (choice == CHOICE_RANDOM) {
        return g_SlotAllowsRandom[slot];
    }
    if (choice < 0) {
        return false;
    }
    return WeaponFits(choice, g_SlotCategories[slot], g_SlotSides[slot])
        && g_WeaponPrice[choice] <= g_SlotMaxPrice[slot];
}

/**
 * Turns a cookie value or a menu item into a slot value: CHOICE_RANDOM, a weapon index,
 * or -1 if it is neither.
 */
int ParseChoice(const char[] id) {
    return StrEqual(id, RANDOM_COOKIE_VALUE) ? CHOICE_RANDOM : FindWeapon(id);
}

void ResetChoices(int client) {
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        g_Choice[client][slot] = DefaultChoice(slot);
    }
    g_AwpChoice[client] = false;
}

/**
 * Reads the choices of a client from the cookies. An empty or unknown value (e.g. one
 * left by the CS:GO version: "m4a1_silencer", "sg556") leaves the default.
 */
void LoadChoices(int client) {
    char id[WEAPON_STRING_LENGTH];
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        GetClientCookie(client, g_hSlotCookie[slot], id, sizeof(id));
        int choice = ParseChoice(id);
        if (IsValidChoice(slot, choice)) {
            g_Choice[client][slot] = choice;
        }
    }
    g_AwpChoice[client] = GetCookieBool(client, g_hAwpCookie);
}

/**
 * Stores a choice and its cookie. The caller has checked it with IsValidChoice.
 */
void SetChoice(int client, int slot, int choice) {
    g_Choice[client][slot] = choice;
    if (choice == CHOICE_RANDOM) {
        SetClientCookie(client, g_hSlotCookie[slot], RANDOM_COOKIE_VALUE);
    } else {
        SetClientCookie(client, g_hSlotCookie[slot], g_Weapons[choice][WEAPON_ID]);
    }
}

void SetAwpChoice(int client, bool allow) {
    g_AwpChoice[client] = allow;
    SetCookieBool(client, g_hAwpCookie, allow);
}
