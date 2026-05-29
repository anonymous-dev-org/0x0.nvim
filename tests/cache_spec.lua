describe("completion cache", function()
  local cache

  before_each(function()
    package.loaded["zxz.complete.cache"] = nil
    cache = require("zxz.complete.cache")
    cache.init(10)
  end)

  it("returns exact cache hits", function()
    local key = cache.make_key("local x = ", "", "lua")
    cache.set(key, "42")

    local hit, matched = cache.get_or_shift("local x = ", "", "lua")
    assert.are.equal("42", hit)
    assert.are.equal(key, matched)
  end)

  it("shifts a cached completion when the typed character matches", function()
    local old_key = cache.make_key("local x = ", "", "lua")
    cache.set(old_key, "42")

    local hit, matched = cache.get_or_shift("local x = 4", "", "lua")
    assert.are.equal("2", hit)
    assert.are.equal(cache.make_key("local x = 4", "", "lua"), matched)
  end)

  it("does not shift when the typed character mismatches", function()
    local old_key = cache.make_key("local x = ", "", "lua")
    cache.set(old_key, "42")

    local hit = cache.get_or_shift("local x = 9", "", "lua")
    assert.is_nil(hit)
  end)
end)
