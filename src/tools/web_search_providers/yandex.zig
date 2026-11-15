//! Yandex Search API provider for web_search.
//!
//! POSTs JSON to https://searchapi.api.cloud.yandex.net/v2/web/search with an
//! `Authorization: Api-Key <key>` header. The API key and folder id are read
//! from the environment by the tool layer (`YC_SEARCH_API_KEY`,
//! `YC_FOLDER_ID`); there is no config field. The HTTP transport routes
//! credentialed requests through a temp file, so the key never appears in
//! process arguments, logs, or rendered output.

const std = @import("std");
const common = @import("common.zig");

const SEARCH_ENDPOINT = "https://searchapi.api.cloud.yandex.net/v2/web/search";
const SEARCH_TYPE_RU = "SEARCH_TYPE_RU";
const FAMILY_MODE_MODERATE = "MODERATE";

pub fn execute(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    api_key: []const u8,
    folder_id: []const u8,
    timeout_secs: u64,
) (common.ProviderSearchError || error{OutOfMemory})!common.ToolResult {
    const timeout_str = try common.timeoutToString(allocator, timeout_secs);
    defer allocator.free(timeout_str);

    const body_json = try buildRequestBody(allocator, query, count, folder_id);
    defer allocator.free(body_json);

    const auth_header = try buildAuthHeader(allocator, api_key);
    defer allocator.free(auth_header);
    const headers = [_][]const u8{
        auth_header,
        "Accept: application/json",
    };

    const response = common.curlPostJsonWithStatus(allocator, SEARCH_ENDPOINT, body_json, &headers, timeout_str) catch |err| {
        common.logRequestError("yandex", query, err);
        return err;
    };
    defer allocator.free(response.body);

    // Terminal, distinguishable failure messages (design D5). Static text
    // only: the API key value must never appear in provider error output.
    if (response.status_code == 401 or response.status_code == 403) {
        return common.ToolResult.fail("Yandex Search API rejected authorization (HTTP 401/403). Verify YC_SEARCH_API_KEY (scope, API activation) and YC_FOLDER_ID.");
    }
    if (response.status_code == 429) {
        return common.ToolResult.fail("Yandex Search API rate limit exceeded (HTTP 429).");
    }

    const result = try formatResults(allocator, response.body, query);
    if (!result.success) return error.InvalidResponse;
    return result;
}

/// Builds the POST body per Yandex Search API v2:
/// `{folderId, query:{queryText, searchType, familyMode}, page:{pageNumber, pageSize}}`.
/// Single page only (pageNumber = 1); `count` maps to pageSize.
pub fn buildRequestBody(allocator: std.mem.Allocator, query: []const u8, count: usize, folder_id: []const u8) ![]u8 {
    const payload = .{
        .folderId = folder_id,
        .query = .{
            .queryText = query,
            .searchType = SEARCH_TYPE_RU,
            .familyMode = FAMILY_MODE_MODERATE,
        },
        .page = .{ .pageNumber = 1, .pageSize = count },
    };
    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

pub fn buildAuthHeader(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Authorization: Api-Key {s}", .{api_key});
}

/// Flattens `groups[].results[]` into the shared results layout. Snippets come
/// from the string `headline` field; `passages` is an array and cannot be used
/// by the shared formatter.
pub fn formatResults(allocator: std.mem.Allocator, json_body: []const u8, query: []const u8) !common.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch
        return common.ToolResult.fail("Failed to parse search response JSON");
    defer parsed.deinit();

    const root_val = switch (parsed.value) {
        .object => |o| o,
        else => return common.ToolResult.fail("Unexpected search response format"),
    };

    const groups = root_val.get("groups") orelse
        return common.noWebResults(allocator);
    const groups_arr = switch (groups) {
        .array => |a| a,
        else => return common.noWebResults(allocator),
    };

    var items: std.ArrayList(std.json.Value) = .empty;
    defer items.deinit(allocator);
    for (groups_arr.items) |group| {
        const group_obj = switch (group) {
            .object => |o| o,
            else => continue,
        };
        const results = group_obj.get("results") orelse continue;
        const results_arr = switch (results) {
            .array => |a| a,
            else => continue,
        };
        try items.appendSlice(allocator, results_arr.items);
    }

    if (items.items.len == 0)
        return common.noWebResults(allocator);

    return common.formatResultsArray(allocator, items.items, query, "headline", null);
}

test "buildRequestBody follows Yandex Search API v2 schema" {
    const body = try buildRequestBody(std.testing.allocator, "zig lang", 5, "folder-1");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"folderId\":\"folder-1\",\"query\":{\"queryText\":\"zig lang\",\"searchType\":\"SEARCH_TYPE_RU\",\"familyMode\":\"MODERATE\"},\"page\":{\"pageNumber\":1,\"pageSize\":5}}",
        body,
    );
}

test "buildAuthHeader uses Api-Key scheme" {
    const header = try buildAuthHeader(std.testing.allocator, "test-key");
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("Authorization: Api-Key test-key", header);
}

test "formatResults flattens groups and renders headline snippets" {
    const json =
        \\{"groups":[
        \\  {"results":[
        \\    {"title":"Zig Language","url":"https://ziglang.org","headline":"Zig is a systems language."},
        \\    {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","headline":"Source code."}
        \\  ]},
        \\  {"results":[
        \\    {"title":"Zig News","url":"https://zig.news","headline":"Community posts."}
        \\  ]}
        \\]}
    ;
    const result = try formatResults(std.testing.allocator, json, "zig lang");
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Results for: zig lang") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "1. Zig Language") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "https://ziglang.org") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "3. Zig News") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Community posts.") != null);
    // No credential material may leak into rendered output.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Api-Key") == null);
}

test "formatResults empty groups" {
    const json = "{\"groups\":[]}";
    const result = try formatResults(std.testing.allocator, json, "nothing");
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("No web results found.", result.output);
}

test "formatResults group without results" {
    const json = "{\"groups\":[{\"results\":[]}]}";
    const result = try formatResults(std.testing.allocator, json, "nothing");
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("No web results found.", result.output);
}

test "formatResults invalid JSON" {
    const result = try formatResults(std.testing.allocator, "not json", "q");
    try std.testing.expect(!result.success);
}
