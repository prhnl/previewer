-- :Preview and the filetype for ImageMagick scripts. Nothing starts until
-- :Preview is run in a buffer.

if vim.g.loaded_previewer then
  return
end
vim.g.loaded_previewer = true

vim.filetype.add({ extension = { mgk = "magick" } })

local actions = {
  on = function() require("previewer").start(0) end,
  off = function() require("previewer").stop(0) end,
  toggle = function() require("previewer").toggle(0) end,
  build = function() require("previewer").build(0) end,
  log = function() require("previewer").log(0) end,
}

vim.api.nvim_create_user_command("Preview", function(args)
  local action = actions[args.args ~= "" and args.args or "toggle"]
  if not action then
    return vim.notify("preview: on, off, toggle, build or log", vim.log.levels.ERROR)
  end
  action()
end, {
  nargs = "?",
  complete = function() return vim.tbl_keys(actions) end,
  desc = "Preview this file: on, off, toggle (default), build now, or show the last build log",
})

vim.keymap.set("n", "<Plug>(preview)", function() require("previewer").toggle(0) end,
  { desc = "Toggle preview" })
