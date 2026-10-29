# 17: massh крашится при установке Agent на Ubuntu

**What to build:** Исправить краш приложения при установке Agent на Server 192.168.0.19 (Ubuntu 24.04.4 LTS, aarch64, systemd, `/bin/sh` → dash, пользователь `lixelv`). Сначала воспроизвести (в контейнере Ubuntu на `TestServerContainer`, подготовка до sudo), найти причину, потом чинить.

**Blocked by:** —

**Status:** needs-triage

**Что известно:** краш-репорты `~/Library/Logs/DiagnosticReports/massh-2026-10-28-{205441,205449,210633}.ips`. Все три падают в AppKit: `NSWindow _postWindowNeedsUpdateConstraints` бросает `NSException` (`abort()`; в третьем `EXC_BREAKPOINT`) из `NSHostingView.setNeedsUpdate` / `LayoutInvalidator.invalidate`. Вероятно цикл раскладки окна (`NavigationSplitView` + `.inspector` + `.toolbar` в `ContentView.swift`), а не сама установка; гипотеза не проверена. Пользователь: падало во время скачивания Agent.

- [ ] Краш воспроизводится (контейнер Ubuntu или тот же сервер до шага sudo)
- [ ] Причина названа в тексте исключения, а не по догадке
- [ ] Установка на Ubuntu 24.04 aarch64 доходит до терминальной вкладки без краша
- [ ] Регресс-проверка добавлена там, где это можно автоматизировать
