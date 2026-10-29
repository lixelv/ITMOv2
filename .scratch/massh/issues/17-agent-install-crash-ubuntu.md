# 17: massh крашится при установке Agent на Ubuntu

**What to build:** Исправить краш приложения при установке Agent на Server 192.168.0.19 (Ubuntu 24.04.4 LTS, aarch64, systemd, `/bin/sh` → dash, пользователь `lixelv`). Сначала воспроизвести (в контейнере Ubuntu на `TestServerContainer`, подготовка до sudo), найти причину, потом чинить.

**Blocked by:** —

**Status:** done

**Что известно:** краш-репорты `~/Library/Logs/DiagnosticReports/massh-2026-10-28-{205441,205449,210633}.ips`. Все три падают в AppKit: `NSWindow _postWindowNeedsUpdateConstraints` бросает `NSException` (`abort()`; в третьем `EXC_BREAKPOINT`) из `NSHostingView.setNeedsUpdate` / `LayoutInvalidator.invalidate`. Вероятно цикл раскладки окна (`NavigationSplitView` + `.inspector` + `.toolbar` в `ContentView.swift`), а не сама установка; гипотеза не проверена. Пользователь: падало во время скачивания Agent.

- [x] Краш воспроизводится (контейнер Ubuntu или тот же сервер до шага sudo)
- [x] Причина названа в тексте исключения, а не по догадке
- [x] Установка на Ubuntu 24.04 aarch64 доходит до терминальной вкладки без краша
- [x] Регресс-проверка добавлена там, где это можно автоматизировать

**Итог: не воспроизводится, закрыто как утратившее смысл.** Установка на Ubuntu 24.04 aarch64 (контейнер `massh-test-server`, как 192.168.0.19) проходит до sudo и после `install` Agent работает — и в текущей сборке, и в сборке до 22 (`80543fe`), в том числе с задержкой сети 400 мс. Краш был циклом раскладки окна вокруг колонки инспектора, которой после 22 нет. Если повторится — открыть заново с шагами.

**Найдено по ходу и исправлено:** если ControlMaster к Server уже есть (свой у пользователя или оставшийся после краша massh), туннель Inspector отдавал проброс этому мастеру, ssh выходил с кодом 0, и Inspector писал «Connection to the Agent lost». Теперь это рабочий туннель (`SSHTunnel.open`), тест `observingThroughAnExistingMaster`.
