// Grenades: how many a player gets and which ones.
// Included only from retakes_allocator.sp.

// Everything a CS:S player can carry: an HE grenade, two flashbangs and a smoke grenade.
// The letters are the ones Retakes_SetPlayerInfo understands.
char g_NadePool[] = "hffs";
#define NADE_POOL_SIZE 4

/**
 * Writes the grenades of one player for a round of the given type: a random number from
 * the range of the round type, picked at random from the pool.
 */
void PickNades(int type, char nades[NADE_STRING_LENGTH]) {
    int order[NADE_POOL_SIZE];
    for (int i = 0; i < NADE_POOL_SIZE; i++) {
        order[i] = i;
    }
    ShuffleInts(order, NADE_POOL_SIZE);

    int count = GetRandomInt(g_TypeNadesMin[type], g_TypeNadesMax[type]);
    if (count > NADE_POOL_SIZE) {
        count = NADE_POOL_SIZE;
    }

    for (int i = 0; i < count; i++) {
        nades[i] = g_NadePool[order[i]];
    }
    nades[count] = '\0';
}
