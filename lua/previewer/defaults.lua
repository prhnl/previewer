-- What :Preview does per filetype. See :help previewer-spec for the fields.
-- Any of these can be changed or switched off (false) through setup().
--
-- swayimg does not notice a changed file by itself; it reloads on SIGUSR2
-- when its config says so:
--   swayimg.viewer.on_signal("USR2", function() swayimg.viewer.reload() end)
-- Without that the signal ends it, and the next build opens a new one.

local image = { view = "swayimg %o", reload = "SIGUSR2" }

local function with(t, base)
  return vim.tbl_extend("keep", t, base)
end

local M = {}

-- By output extension, for a spec without a view: a script that writes its
-- own picture, say.
M.viewers = {
  html = { view = "browser" }, htm = { view = "browser" },
  png = image, jpg = image, jpeg = image, gif = image, webp = image, svg = image,
  pdf = { view = "zathura %o" },
}

M.filetypes = {
  -- Relative links resolve against the file's directory: the page is served
  -- from there.
  markdown = {
    build = "pandoc --standalone --metadata pagetitle=%t --output %o",
    stdin = true,
    ext = "html",
    view = "browser",
  },
  -- Served as is; saving a stylesheet or script beside it reloads it too.
  html = { view = "browser" },

  svg = with({}, image),

  -- An ImageMagick script (magick -script), read from the buffer. Whatever
  -- the image is at the end of it gets written to the preview; -write lines
  -- of its own still write where they say.
  magick = with({
    build = "magick -script -",
    stdin = function(ctx) return ctx.text .. ('\n-write "%s"\n'):format(ctx.output) end,
    ext = "png",
  }, image),

  dot = with({ build = "dot -Tsvg -o %o", stdin = true, ext = "svg" }, image),

  gnuplot = with({
    build = { "gnuplot", "-e", "set terminal pngcairo size 1200,800; set output '%o'", "-" },
    stdin = true,
    ext = "png",
  }, image),

  -- zathura reloads a changed file by itself.
  typst = { build = "typst compile %f %o", ext = "pdf", view = "zathura %o" },
}

return M
