-- mod_moderator_control.lua
module:hook("muc-occupant-pre-join", function(event)
    local occupant = event.occupant;
    local session = event.origin;
    local token = session.auth_token;

    -- If no token or no user context with moderator flag, not a moderator
    if not token or not token.context or not token.context.user or token.context.user.moderator ~= true then
        occupant.role = "participant";
    end
end, 2);  -- Priority 2 to run after other hooks