# Create: Copycats+ 3.0.9 — KxCraft modpack notice

- Project: Create: Copycats+ by Lysine, Bennyboy1695, and Redcat_XVIII.
- Exact upstream release: [Modrinth version bPYeUWZx](https://modrinth.com/mod/copycats/version/bPYeUWZx), Minecraft 1.21.1 / NeoForge.
- Official artifact SHA-256: d1efdd8688af6603dff9425299ac4547ef56a7d5cfee757716ead7853276694e (1,799,381 bytes).
- KxCraft artifact SHA-256: $expectedJarHash (1,800,584 bytes). This is the exact existing client-profile JAR; it was not replaced or rebuilt.
- Upstream modpack permission: the multiloader README at commit [$upstreamCommit](https://github.com/copycats-plus/copycats/blob/787135d1ae89adbcd455c85ce482a234a55303e0/README.MD) permits including the mod in any modpack and modifying it for distribution in a modpack. This notice relies on that specific grant and does not claim a general license beyond it; the JAR metadata states All Rights Reserved.

## KxCraft change

The only functional change is removal of data/copycats/physics_block_properties/copycat_catwalk.json. The file selects copycats:copycat_catwalk, which upstream issue [#437](https://github.com/copycats-plus/copycats/issues/437) documents as an unregistered block ID; the Catwalk item is backed by copycats:copycat_board. Removing the entry avoids applying an invalid Sable selector. It does **not** add Catwalk-specific mass/volume values; mapping to the board would also affect regular Copycat Board, as the issue describes.

All 412 same-path JSON resources compared semantically equal; two text resources differ only in line endings. The generated PlatformMethods class moved to a hash-qualified package path, with bytecode unchanged (getCurrentTarget() returns 
eoforge). The remaining same-path entries are byte-identical. No other functional change was found in the JAR comparison.