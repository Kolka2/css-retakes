// The weapon table of the allocator: every firearm of CS:S with its price, side and category.
// Included only from retakes_allocator.sp.

// Weapon categories, bit flags. The order must match g_CategoryNames.
#define CAT_STARTER (1 << 0) // the pistol a side starts with
#define CAT_PISTOL  (1 << 1) // the pistols that have to be bought
#define CAT_SMG     (1 << 2)
#define CAT_SHOTGUN (1 << 3)
#define CAT_RIFLE   (1 << 4)
#define CAT_SNIPER  (1 << 5)
#define CAT_MG      (1 << 6)
#define CAT_ANY_PRIMARY (CAT_SMG | CAT_SHOTGUN | CAT_RIFLE | CAT_SNIPER | CAT_MG)

char g_CategoryNames[][] = { "starter", "pistol", "smg", "shotgun", "rifle", "sniper", "mg" };

// Which side can buy a weapon in the game, bit flags.
#define SIDE_T    (1 << 0)
#define SIDE_CT   (1 << 1)
#define SIDE_BOTH (SIDE_T | SIDE_CT)

// Indices of a side in two-element arrays (g_Rifle, g_DefaultRifle and so on).
#define T_INDEX 0
#define CT_INDEX 1

// Columns of g_Weapons.
#define WEAPON_ID 0       // class name without "weapon_"; also what the cookies store
#define WEAPON_NAME 1     // menu name
#define WEAPON_PRICE 2    // CS:S buy menu price
#define WEAPON_SIDE 3     // "t", "ct" or "" for both
#define WEAPON_CATEGORY 4 // one of g_CategoryNames

// One row per weapon; everything else in the allocator is derived from this table.
char g_Weapons[][][] = {
    { "glock",     "Glock",        "400",  "",   "starter" },
    { "usp",       "USP",          "500",  "",   "starter" },
    { "p228",      "P228",         "600",  "",   "pistol" },
    { "deagle",    "Desert Eagle", "650",  "",   "pistol" },
    { "fiveseven", "Five-SeveN",   "750",  "ct", "pistol" },
    { "elite",     "Dual Elites",  "800",  "t",  "pistol" },

    { "tmp",       "TMP",          "1250", "ct", "smg" },
    { "mac10",     "MAC-10",       "1400", "t",  "smg" },
    { "mp5navy",   "MP5",          "1500", "",   "smg" },
    { "ump45",     "UMP-45",       "1700", "",   "smg" },
    { "p90",       "P90",          "2350", "",   "smg" },

    { "m3",        "M3",           "1700", "",   "shotgun" },
    { "xm1014",    "XM1014",       "3000", "",   "shotgun" },

    { "ak47",      "AK-47",        "2500", "t",  "rifle" },
    { "m4a1",      "M4A1",         "3100", "ct", "rifle" },
    { "galil",     "Galil",        "2000", "t",  "rifle" },
    { "famas",     "FAMAS",        "2250", "ct", "rifle" },
    { "sg552",     "SG 552",       "3500", "t",  "rifle" },
    { "aug",       "AUG",          "3500", "ct", "rifle" },

    { "scout",     "Scout",        "2750", "",   "sniper" },
    { "awp",       "AWP",          "4750", "",   "sniper" },
    { "g3sg1",     "G3SG1",        "5000", "t",  "sniper" },
    { "sg550",     "SG 550",       "4200", "ct", "sniper" },

    { "m249",      "M249",         "5750", "",   "mg" },
};

// The numeric columns of g_Weapons, filled by ParseWeapons().
int g_WeaponPrice[sizeof(g_Weapons)];
int g_WeaponSides[sizeof(g_Weapons)];
int g_WeaponCategory[sizeof(g_Weapons)];

// Weapons the code refers to by name, as indices into g_Weapons.
int g_DefaultPistol[2];
int g_DefaultRifle[2];
int g_Awp;

int SideIndex(bool ct) {
    return ct ? CT_INDEX : T_INDEX;
}

/**
 * Returns the index of a weapon in g_Weapons by its id ("ak47"), or -1.
 */
int FindWeapon(const char[] id) {
    for (int i = 0; i < sizeof(g_Weapons); i++) {
        if (StrEqual(id, g_Weapons[i][WEAPON_ID], true)) {
            return i;
        }
    }
    return -1;
}

/**
 * Same as FindWeapon, for the weapons the plugin cannot work without.
 */
static int RequireWeapon(const char[] id) {
    int weapon = FindWeapon(id);
    if (weapon == -1) {
        SetFailState("Weapon \"%s\" is missing from the weapon table", id);
    }
    return weapon;
}

/**
 * Fills the numeric columns of the weapon table. Called once, when the plugin starts.
 */
void ParseWeapons() {
    for (int i = 0; i < sizeof(g_Weapons); i++) {
        g_WeaponPrice[i] = StringToInt(g_Weapons[i][WEAPON_PRICE]);

        if (StrEqual(g_Weapons[i][WEAPON_SIDE], "t")) {
            g_WeaponSides[i] = SIDE_T;
        } else if (StrEqual(g_Weapons[i][WEAPON_SIDE], "ct")) {
            g_WeaponSides[i] = SIDE_CT;
        } else {
            g_WeaponSides[i] = SIDE_BOTH;
        }

        g_WeaponCategory[i] = 0;
        for (int c = 0; c < sizeof(g_CategoryNames); c++) {
            if (StrEqual(g_Weapons[i][WEAPON_CATEGORY], g_CategoryNames[c])) {
                g_WeaponCategory[i] = (1 << c);
            }
        }
        if (g_WeaponCategory[i] == 0) {
            SetFailState("Weapon \"%s\" has an unknown category \"%s\"",
                         g_Weapons[i][WEAPON_ID], g_Weapons[i][WEAPON_CATEGORY]);
        }
    }

    g_DefaultPistol[T_INDEX] = RequireWeapon("glock");
    g_DefaultPistol[CT_INDEX] = RequireWeapon("usp");
    g_DefaultRifle[T_INDEX] = RequireWeapon("ak47");
    g_DefaultRifle[CT_INDEX] = RequireWeapon("m4a1");
    g_Awp = RequireWeapon("awp");
}

/**
 * Returns if a side can have a weapon of one of the given categories.
 */
bool WeaponFits(int weapon, int categories, bool ct) {
    return (g_WeaponCategory[weapon] & categories) != 0
        && (g_WeaponSides[weapon] & (ct ? SIDE_CT : SIDE_T)) != 0;
}

/**
 * Picks a random weapon of the given categories that the side can have and that costs
 * no more than maxPrice. Returns -1 if there is no such weapon.
 */
int RandomWeapon(int categories, bool ct, int maxPrice) {
    int candidates[sizeof(g_Weapons)];
    int count = 0;
    for (int i = 0; i < sizeof(g_Weapons); i++) {
        if (WeaponFits(i, categories, ct) && g_WeaponPrice[i] <= maxPrice) {
            candidates[count++] = i;
        }
    }
    return count > 0 ? candidates[GetRandomInt(0, count - 1)] : -1;
}

/**
 * Writes the class name of a weapon ("weapon_ak47"); an empty string for -1.
 */
void GetWeaponClass(int weapon, char[] buffer, int size) {
    if (weapon == -1) {
        buffer[0] = '\0';
    } else {
        Format(buffer, size, "weapon_%s", g_Weapons[weapon][WEAPON_ID]);
    }
}

/**
 * Shuffles the first count elements of an array.
 */
void ShuffleInts(int[] values, int count) {
    for (int i = count - 1; i > 0; i--) {
        int j = GetRandomInt(0, i);
        int tmp = values[i];
        values[i] = values[j];
        values[j] = tmp;
    }
}
