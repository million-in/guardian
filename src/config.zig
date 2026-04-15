const config_loader = @import("config_loader.zig");
const config_schema = @import("config_schema.zig");

pub const SurfaceScope = config_schema.SurfaceScope;
pub const Pattern = config_schema.Pattern;
pub const Limits = config_schema.Limits;
pub const LimitsPatch = config_schema.LimitsPatch;
pub const Scan = config_schema.Scan;
pub const GoRules = config_schema.GoRules;
pub const GoRulesPatch = config_schema.GoRulesPatch;
pub const TypeScriptRules = config_schema.TypeScriptRules;
pub const TypeScriptRulesPatch = config_schema.TypeScriptRulesPatch;
pub const PythonRules = config_schema.PythonRules;
pub const PythonRulesPatch = config_schema.PythonRulesPatch;
pub const ZigRules = config_schema.ZigRules;
pub const ZigRulesPatch = config_schema.ZigRulesPatch;
pub const Override = config_schema.Override;
pub const Config = config_schema.Config;

pub const LoadedConfig = config_loader.LoadedConfig;
pub const default_cache_key = config_loader.default_cache_key;
pub const loadForTarget = config_loader.loadForTarget;
pub const resolveCacheKey = config_loader.resolveCacheKey;
pub const isDefaultCacheKey = config_loader.isDefaultCacheKey;

test {
    _ = @import("config_schema.zig");
    _ = @import("config_loader.zig");
}
