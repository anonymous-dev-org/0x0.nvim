if exists('g:loaded_zeroxzero')
  finish
endif
let g:loaded_zeroxzero = 1

command! ZeroToggle              lua require('zeroxzero').toggle()
command! -range ZeroContext       lua require('zeroxzero').context()
command! ZeroSession             lua require('zeroxzero').session()
command! ZeroInterrupt           lua require('zeroxzero').interrupt()
command! ZeroModel               lua require('zeroxzero').model()
command! ZeroInlineEdit          lua require('zeroxzero').inline_edit()
