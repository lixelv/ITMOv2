# 14: MasshApp: редактор Server

**What to build:** Добавление и правка Server через форму с шестью полями, удаление с подтверждением. Server из `Include` открываются только для чтения. Ошибки хранилища (занятое имя и т.п.) показываются пользователю. На фейковом хранилище.

**Blocked by:** 10

**Status:** done

- [x] Форма добавления из тулбара; новый Server появляется в Server List
- [x] Форма правки из контекстного меню
- [x] Удаление только после подтверждения
- [x] Server из `Include` открываются в режиме только для чтения
- [x] Ошибка хранилища показывается в форме

## Comments

- Implementation note: the background UI driver could not overwrite the IdentityFile text field during the manual check; the field works with the keyboard. Edits from outside (vim) are picked up live.
