# 10: MasshApp: каркас окна в стиле Xcode

**What to build:** Приложение открывает окно в стиле Xcode с Liquid Glass: сайдбар с Server List и отметками Online/Offline/Unknown, рабочая область, инспектор, тулбар (подключиться, добавить Server, показать/скрыть инспектор). Работает на фейках из MasshCore.

**Blocked by:** 01

**Status:** done

- [x] Минимальная версия — macOS 26, App Sandbox выключен
- [x] Трёхколоночная раскладка; инспектор скрывается/показывается кнопкой
- [x] Server List с отметками статуса из фейкового монитора
- [x] Server из `Include` визуально отличаются (только для чтения)
- [x] Стандартные контролы, Liquid Glass, светлая и тёмная тема
- [x] SwiftUI Previews на фейках

## Comments

- MasshApp is a SwiftPM package (`MasshUI` library with Previews + `massh` executable) bundled by `MasshApp/bundle.sh`, instead of an Xcode project. SwiftTerm is pinned to 1.11.2: 1.12+ needs the separately downloaded Metal toolchain.
