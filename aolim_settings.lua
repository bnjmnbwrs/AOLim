-- aolim_settings.lua
-- Basic config for AOLim (HorizonXI + Ashita)

return {
    window = {
        is_open = true,
        x = 200,
        y = 200,
        w = 520,
        h = 420
    },

    presence = {
        -- Minimum seconds between /sea checks per buddy.
        per_buddy_cooldown = 20,

        -- Minimum seconds between any two /sea checks overall.
        global_cooldown = 3,

        -- Auto-watch rotation delay (seconds).
        watch_interval = 10,

        -- Auto-watch enabled on load?
        watch_enabled = false,

        -- /sea result must arrive within this many seconds to be accepted:
        result_accept_window = 2
    }
}
