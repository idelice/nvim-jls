local ok, jls = pcall(require, "jls")
if ok and jls and jls.start then
  jls.start()
end
