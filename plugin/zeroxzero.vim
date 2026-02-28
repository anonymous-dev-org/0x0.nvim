if exists('g:loaded_zeroxzero')
  finish
endif
let g:loaded_zeroxzero = 1

" Terminal management
command! ZeroOpen    lua require('zeroxzero').open()
command! ZeroToggle  lua require('zeroxzero').toggle()
command! ZeroClose   lua require('zeroxzero').close()

" Context injection
command! ZeroAddFile      lua require('zeroxzero').add_file()
command! -range ZeroAddSelection lua require('zeroxzero').add_selection()

" Ask
command! -nargs=? ZeroAsk lua require('zeroxzero').ask({ default = <q-args> })

" Session management
command! ZeroSessionList      lua require('zeroxzero').session_list()
command! ZeroSessionNew       lua require('zeroxzero').session_new()
command! ZeroSessionInterrupt lua require('zeroxzero').session_interrupt()

" Model
command! ZeroModelList lua require('zeroxzero').model_list()

" Commands & Agents (fetched from server, defined in config.yaml)
command! ZeroCommandPicker lua require('zeroxzero').command_picker()
command! ZeroAgentPicker   lua require('zeroxzero').agent_picker()

" Inline edit
command! ZeroInlineEdit lua require('zeroxzero').inline_edit()
