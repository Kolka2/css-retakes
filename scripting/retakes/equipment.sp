// Player equipment: weapons, armor, money and the purchase block.
// Included only from retakes.sp.

/**
 * Blocks every purchase while the game is live: retakes hands out the equipment itself.
 * Buying stays available in the warmup (and in the spawn editor).
 *
 * Checked on a live CS:S server: this cancels a purchase made through the buy menu as
 * well as through the "buy" command. That is why the kill and round rewards are not
 * zeroed: they pile up until the next round starts (GiveWeapons resets them there), but
 * there is nothing to spend them on.
 */
public Action CS_OnBuyCommand(int client, const char[] weapon) {
    if (!g_Enabled || InFreePlay()) {
        return Plugin_Continue;
    }
    return Plugin_Handled;
}

/**
 * Removes (and destroys) every weapon the client is carrying, apart from the
 * weapon entity passed as "except".
 *
 * The reserve ammo of a removed weapon is zeroed as well. In CS:S the ammo belongs to
 * the player, not to the weapon, and a grenade is one unit of such ammo: a player who
 * survived a round with an unused flashbang kept that unit, and the flashbang given in
 * the next round made it two (the flashbang limit is 2, so only this grenade showed it).
 */
static void RemoveAllWeapons(int client, int except = -1) {
    int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < size; i++) {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon > MaxClients && weapon != except && IsValidEntity(weapon)) {
            // Checked on a live CS:S server: zeroing m_iAmmo for the weapon's ammo type
            // drops a grenade count left over from the previous round.
            if (HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType")) {
                int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
                if (ammoType >= 0) {
                    SetEntProp(client, Prop_Send, "m_iAmmo", 0, _, ammoType);
                }
            }
            RemovePlayerItem(client, weapon);
            AcceptEntityInput(weapon, "Kill");
        }
    }
}

/**
 * Gives a weapon by its class name. Empty names are skipped (an allocator may leave
 * the primary weapon empty). Returns the weapon entity or -1.
 */
static int GiveWeapon(int client, const char[] weapon) {
    if (weapon[0] == '\0') {
        return -1;
    }

    int entity = GivePlayerItem(client, weapon);
    if (entity == -1) {
        // Most likely a CS:GO weapon name coming from a third-party allocator.
        LogError("Failed to give \"%s\" to %L: no such weapon in CS:S?", weapon, client);
    }
    return entity;
}

/**
 * Fills the reserve ammo of one firearm the client was just given.
 *
 * Only the primary weapon and the pistol go through here. Grenades must not: an earlier
 * version refilled everything the player carried and relied on grenades having no clip,
 * but on a live CS:S server that gave a second flashbang (the flashbang ammo limit is 2).
 */
static void RefillWeaponAmmo(int client, int weapon) {
    if (weapon <= MaxClients || !IsValidEntity(weapon)) {
        return;
    }
    if (!HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType")) {
        return;
    }

    int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
    if (ammoType >= 0) {
        // Checked on a live CS:S server: GivePlayerAmmo in CS:S clamps the reserve to the maximum of the ammo
        // type (AK-47: 30/90, not 30/999), and a weapon from GivePlayerItem has a full clip.
        GivePlayerAmmo(client, 999, ammoType, true);
    }
}

/**
 * Gives a client the loadout stored for the round (g_PlayerPrimary and friends).
 */
void GiveWeapons(int client) {
    if (!IsValidClient(client)) {
        return;
    }

    // The C4 is left alone: the game may already have given it to this player, and
    // FixBomb() sorts the bombs out after everybody is equipped.
    RemoveAllWeapons(client, GetClientC4(client));

    // CS:S has one knife for both teams (there is no weapon_knife_t).
    GiveWeapon(client, "weapon_knife");
    RefillWeaponAmmo(client, GiveWeapon(client, g_PlayerPrimary[client]));
    RefillWeaponAmmo(client, GiveWeapon(client, g_PlayerSecondary[client]));

    SetEntProp(client, Prop_Send, "m_ArmorValue", g_PlayerArmor[client]);
    SetEntityHealth(client, g_PlayerHealth[client]);
    SetEntProp(client, Prop_Send, "m_bHasHelmet", g_PlayerHelmet[client]);
    SetEntProp(client, Prop_Send, "m_bHasDefuser", g_Team[client] == CS_TEAM_CT && g_PlayerKit[client]);

    // CS:S only has the HE grenade, the flashbang and the smoke grenade.
    // The other letters (m, i, d from CS:GO) are silently skipped.
    int len = strlen(g_PlayerNades[client]);
    for (int i = 0; i < len; i++) {
        switch (g_PlayerNades[client][i]) {
            case 'h': GiveWeapon(client, "weapon_hegrenade");
            case 'f': GiveWeapon(client, "weapon_flashbang");
            case 's': GiveWeapon(client, "weapon_smokegrenade");
        }
    }

    // Retakes hands out the equipment itself, so nobody (the bots first of all) should be
    // able to buy on top of it.
    SetEntProp(client, Prop_Send, "m_iAccount", 0);

    // The C4 is not given here: FixBomb() does it once everybody has spawned.
}
