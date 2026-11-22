-- Baggler Camping section: the item IDs that belong in it (not recipe/spell data).
-- Item IDs collected 2026-11-14 for World of Warcraft: Forever.
-- Coverage: 39 outputs + 26 blueprints + 4 fire supplies + 6 dedicated reagents
-- + 1 cosmetic = 76 distinct inventory item IDs. Generic shared materials/tools
-- deliberately remain under their existing professions/item-class categories.
-- Item-record URL for each key: https://forever.warcraftdb.com/data/item/<ID>
-- Coverage cross-check: https://wow-professions.com/forever/camping-guide
-- System reference: https://news.blizzard.com/en-us/article/24301516/gather-around-the-campfire-in-world-of-warcraft-forever
-- Only item IDs and names are listed here; no guide text is copied.
local ADDON, CB = ...
CB.CampingData = {
  -- firemaking supplies
  [4470] = true, -- Simple Wood
  [4471] = true, -- Flint and Tinder
  [11291] = true, -- Star Wood
  [272941] = true, -- Thick Logs
  -- dedicated output items
  [279938] = true, -- Trapper's Workbench
  [279940] = true, -- Toxin Study
  [279941] = true, -- Tanning Rack
  [279943] = true, -- Spinning Wheel
  [279944] = true, -- Sharpening Wheel
  [279945] = true, -- Sewing Machine
  [279947] = true, -- Seed Hybridizer
  [279948] = true, -- Rock Garden
  [279949] = true, -- Repair Bot
  [279950] = true, -- Reagent Bot
  [279951] = true, -- Plague Doctor's Laboratory
  [279952] = true, -- Molten Foundry
  [279955] = true, -- Master Forge
  [279956] = true, -- Mana Well
  [279957] = true, -- Cookie's Feast
  [279959] = true, -- Loom
  [279960] = true, -- Lodestone
  [279961] = true, -- Journeyman Campfire Kit
  [279962] = true, -- Incense Candle
  [279964] = true, -- Greenhouse
  [279965] = true, -- Fishing Rack
  [279966] = true, -- Fishing Hut
  [279967] = true, -- Fish Bowl
  [279968] = true, -- First Aid Kit
  [279969] = true, -- Field Guide
  [279970] = true, -- Fermenter
  [279972] = true, -- Faction Banner
  [279973] = true, -- Faction Banner
  [279974] = true, -- Expert Campfire Kit
  [279976] = true, -- Enchanted Lute
  [279978] = true, -- Camp Tent
  [279979] = true, -- Camp Chair
  [279981] = true, -- Basic Campfire Kit
  [279982] = true, -- Iron Oven
  [279985] = true, -- Arcane Salvager
  [279987] = true, -- Arcane Forge
  [279988] = true, -- Anvil
  [279989] = true, -- Anarchist's Workbench
  [279990] = true, -- Alchemy Laboratory
  -- blueprints
  [273085] = true, -- Blueprint: Fermenter
  [273086] = true, -- Blueprint: Anvil
  [273087] = true, -- Blueprint: Journeyman Campfire
  [273092] = true, -- Blueprint: Repair Bot
  [273096] = true, -- Blueprint: Tanning Rack
  [273097] = true, -- Blueprint: Rock Garden
  [273098] = true, -- Blueprint: Field Guide
  [273099] = true, -- Blueprint: Spinning Wheel
  [273101] = true, -- Blueprint: Expert Campfire
  [273102] = true, -- Blueprint: Cookie's Feast
  [273103] = true, -- Blueprint: Arcane Salvager
  [273105] = true, -- Blueprint: Toxin Study
  [273106] = true, -- Blueprint: Greenhouse
  [273109] = true, -- Blueprint: Trapper's Workbench
  [273112] = true, -- Blueprint: Alchemy Laboratory
  [273113] = true, -- Blueprint: Master Forge
  [273115] = true, -- Blueprint: Iron Oven
  [273116] = true, -- Blueprint: Arcane Forge
  [273117] = true, -- Blueprint: Anarchist's Workbench
  [273118] = true, -- Blueprint: Plague Doctor's Laboratory
  [273119] = true, -- Blueprint: Fishing Hut
  [273120] = true, -- Blueprint: Seed Hybridizer
  [273121] = true, -- Blueprint: Sewing Machine
  [273122] = true, -- Blueprint: Molten Foundry
  [273124] = true, -- Blueprint: Loom
  [273141] = true, -- Blueprint: Fishing Rack
  -- dedicated station reagents
  [273125] = true, -- Lich's Index Finger
  [273127] = true, -- Golem Heart
  [273128] = true, -- Maker's Spark
  [273129] = true, -- Essence of Anarchy
  [273130] = true, -- Undeath Engine
  [273131] = true, -- Bottled Screams
  -- cosmetic camp items
  [278030] = true, -- Scarlet Banner
}
