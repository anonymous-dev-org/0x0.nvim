if exists('g:loaded_zeroxzero')
  finish
endif
let g:loaded_zeroxzero = 1

command! ZeroSend  lua require('zeroxzero').send()
