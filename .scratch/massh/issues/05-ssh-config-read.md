# 05: MasshCore: чтение `~/.ssh/config`

**What to build:** MasshCore читает `~/.ssh/config` и выдаёт Server List: по Server на каждый блок `Host` без шаблонов, включая Server из `Include`-файлов (помеченные как только для чтения). Внешние изменения файла приводят к обновлению Server List.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] Модель файла хранит его без потерь: чтение и запись без изменений совпадают с исходником побайтно (тест на наборе реальных конфигов)
- [x] Блоки с `*`/`?` в имени не попадают в Server List
- [x] `Include` (в т.ч. с глобами и относительными путями) разворачивается, такие Server помечены только для чтения
- [x] Для Server доступны имя, HostName, User, Port, IdentityFile, ProxyJump
- [x] Изменение файла снаружи порождает новое значение Server List
- [x] TDD, `swift test` проходит
