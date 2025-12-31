local jls = require("jls")

describe("defaults", function()
  it("has default java filetypes", function()
    assert(jls.config.filetypes[1] == "java")
  end)
end)
