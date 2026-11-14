// What the players chose in the !guns menu, and the cookies that remember it.
// Included only from retakes_allocator.sp.

// Where the primary weapon of a round type comes from. The order must match g_PrimaryNames.
enum PrimaryPolicy {
    Primary_None = 0, // no primary weapon
    Primary_Random,   // a random one the budget allows
    Primary_Rifle,    // the rifle the player chose; the AWP for one player that asked for it
    Primary_Free,     // any weapon of the game, and any pistol with it, as the player chose
};

char g_PrimaryNames[][] = { "none", "random", "rifle", "free" };

// A choice slot is one weapon setting of a player. The first two are indexed by
// T_INDEX / CT_INDEX.
#define SLOT_T_RIFLE 0
#define SLOT_CT_RIFLE 1
#define SLOT_FREE_PRIMARY 2
#define SLOT_FREE_PISTOL 3
#define NUM_SLOTS 4

// A slot value that is not a weapon: a random weapon every round.
// (-1 is taken: FindWeapon returns it for an unknown weapon.)
#define CHOICE_RANDOM -2
#define RANDOM_COOKIE_VALUE "random"

// The slot table. The rifle cookies have the names retakes_standardallocator uses, so
// the players keep their choice when the server moves to this allocator.
char g_SlotCookieNames[NUM_SLOTS][] = {
    "retakes_triflechoice",
    "retakes_ctriflechoice",
    "retakes_alloc_freeprimary",
    "retakes_alloc_freepistol",
};
// Phrases "Menu<name>" (main menu line) and "Select<name>" (title of the weapon list).
char g_SlotPhrases[NUM_SLOTS][] = { "TRifle", "CTRifle", "FreePrimary", "FreePistol" };
// The weapons a slot offers.
int g_SlotCategories[NUM_SLOTS] = { CAT_RIFLE, CAT_RIFLE, CAT_ANY_PRIMARY, CAT_ANY_PISTOL };
int g_SlotSides[NUM_SLOTS] = { SIDE_T, SIDE_CT, SIDE_BOTH, SIDE_BOTH };
// If the slot offers "random every round"; that is also its default value.
bool g_SlotAllowsRandom[NUM_SLOTS] = { false, false, true, true };
// The round types that use the slot: it is only shown in the menu if one is played.
PrimaryPolicy g_SlotPolicy[NUM_SLOTS] = { Primary_Rifle, Primary_Rifle, Primary_Free, Primary_Free };

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
    return g_SlotAllowsRandom[slot] ? CHOICE_RANDOM : g_DefaultRifle[slot];
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
    return WeaponFits(choice, g_SlotCategories[slot], g_SlotSides[slot]);
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

/**
 * Returns the weapon a slot gives the client this round: the chosen one, or a random
 * weapon of the slot for "random every round".
 */
int ResolveChoice(int client, int slot) {
    int choice = g_Choice[client][slot];
    if (choice == CHOICE_RANDOM) {
        // every slot offers at least one weapon, so this never fails
        choice = RandomWeapon(g_SlotCategories[slot], g_SlotSides[slot], 16000);
    }
    return choice;
}
