# massh Design Language

## Visual Theme

**Точный, плотный, приборная панель.**

massh выглядит как родное приложение macOS, внутри которого стоит инженерный прибор. Каркас окна (тулбар, сайдбар, стекло, кнопки) принадлежит системе (ADR 0003). Характер появляется в области данных: машинные значения набраны моноширинным шрифтом, полоски тонкие и меняют цвет по порогу, цвета Vercel Geist. Ориентиры: Xcode и «Мониторинг системы» для каркаса, Vercel и Geist для данных.

## Color Palette

Все цвета берутся из `Geist` (`Sources/MasshUI/Geist.swift`): это опубликованные токены Vercel со светлым и тёмным вариантами. Фоны, разделители и вторичный текст системные (`.background`, `.secondary`, `.tertiary`, `.quaternary`), чтобы оставаться в согласии со стеклом и материалами.

### Neutrals

| Token | Light | Dark | Role |
|---|---|---|---|
| `Geist.background` | #FFFFFF | #000000 | Фон терминала |
| `Geist.gray1000` | #171717 | #EDEDED | Текст терминала |
| `Geist.gray900` | #4D4D4D | #A0A0A0 | Вторая серия на графиках |
| `Geist.gray700` | #8F8F8F | #8F8F8F | Status Unknown, обводка карточек (с прозрачностью 0.35) |

### Brand / Primary

| Token | Light | Dark | Role |
|---|---|---|---|
| `Geist.blue` | #006BFF | #006EFE | AccentColor, полоски в норме, первая серия на графиках |
| `Geist.blueText` | #005FF2 | #47A8FF | Акцентный текст, чипы портов «наружу» |

### Semantic

| Role | Token | Light | Dark | Meaning |
|---|---|---|---|---|
| Success | `Geist.green` | #28A948 | #00AC3A | Server Online, Container работает |
| Warning | `Geist.amber` | #FFAE00 | #FFAE00 | Полоска выше 80 %, Container на паузе |
| Error | `Geist.red` | #FC0035 | #F13242 | Полоска выше 90 %, Server Offline, Container остановлен |
| Info | `Geist.blue` | | | Норма, акцент |

Цвет никогда не единственный носитель смысла: у статуса всегда есть значок SF Symbol другой формы и текст.

## Typography

**Families:** SF Pro (системный) для интерфейса + SF Mono (`.monospaced()`) для машинных данных. Оба установлены вместе с macOS.
**Scale:** системные стили macOS (Dynamic Type), без собственных размеров.

| Style | macOS size | Role |
|---|---|---|
| `.title3` | 15 | Заголовок секции Inspector |
| `.headline` | 13 semibold | Имя Container, заголовок плашки |
| `.body` | 13 | Основной текст, имя Process |
| `.callout` | 12 | Пояснения в плашках |
| `.caption` | 10 | Подписи, пользователь и PID |
| `.caption2` / mono 11 | 10–11 | Чипы портов, образ Container, команда Process |

**Машинные данные** (адрес, порт, PID, образ, команда, путь) набираются `.monospaced()`. **Числа, которые меняются** (проценты, байты, скорость), набираются `.monospacedDigit()` и анимируются `.contentTransition(.numericText())`, чтобы обновления раз в секунду не дёргали вёрстку.

## Components

| Component | Hierarchy | Purpose | Key Variants |
|---|---|---|---|
| `MeterBar` | Primitive | Тонкая полоска заполнения (4 pt), цвет по порогу | threshold: none / 80–90 % |
| `Chip` | Primitive | Капсула с моноширинным текстом для порта или метки | tone: accent (наружу) / neutral (localhost) |
| `StatusBadge` | Primitive | Значок + цвет + текст статуса | running / paused / stopped / unknown |
| `Meter` | Component | Подпись, живое значение и `MeterBar` под ними | с порогами / без (RAM Process) |
| `HistoryChart` | Component | Swift Charts с историей с момента подключения. **По умолчанию выключен** (вызовы закомментированы в `OverviewView`) | одна или две серии |
| `InspectorBanner` | Component | Плашка состояния на стекле | update / lost / reconnecting |
| `Card` | Component | Обводка 1 pt `gray700` 35 %, скругление 8, отступ 12 | Container, плитка Overview |
| `InspectorSection` | Pattern | Сворачиваемая секция с закреплённым заголовком и счётчиком | Overview / Containers / Processes / Ports |
| Inspector page | Template | Одна прокручиваемая страница с секциями (ADR 0007) | — |

## Layout

**Grid:** адаптивные сетки SwiftUI (`GridItem(.adaptive(minimum:))`), без фиксированных колонок: карточки Container от 260, плитки Overview от 280.
**Base unit:** 4 pt.
**Spacing scale** (`Space` в `Geist.swift`): xs = 4, sm = 8, md = 12, lg = 16, xl = 24.
**Radius** (`Radius`): bar = 2, control = 6, card = 8, floating = 12 (стеклянные плашки и панели поверх контента). Чипы капсульные.

## Depth

Теней нет. Глубину даёт система:

| Level | Treatment | Used for |
|---|---|---|
| 0 | Без фона | Содержимое секций |
| 1 | Обводка 1 pt `gray700` 35 % | Карточки, плитки |
| 2 | `.glassEffect(.regular)` | Плашки состояния и панели поверх контента |
| Chrome | Системные материалы | Тулбар, сайдбар |

## Do's and Don'ts

### Do

- Набирать машинные значения `.monospaced()`, а меняющиеся числа `.monospacedDigit()`.
- Брать цвета только из `Geist` или системных стилей (`.secondary`, `.quaternary`).
- Брать отступы и скругления только из `Space` и `Radius`.
- Показывать статус значком, цветом и текстом сразу.
- Приглушать неживые данные (opacity 0.45, без насыщенности), а не скрывать их.

### Don't

- Не добавлять тени и собственные «стеклянные» фоны: стекло только системное.
- Не использовать произвольные шестнадцатеричные цвета и магические числа отступов.
- Не красить текст в зелёный или красный без значка.
- Не рисовать таблицы `Table` в Inspector: данные показываются карточками, строками и чипами.
- Не анимировать данные дольше 0,3 с: обновления раз в секунду не должны «плыть».

## Responsive

Окно от 900 × 520. Сетки Inspector адаптивные: на узком окне 1–2 карточки в ряду, на широком 3–4. Длинные строки (команда, образ) обрезаются посередине и показывают полный текст в подсказке.

## Agent Prompt Guide

- Каркас окна системный (ADR 0003): стандартные контролы, Liquid Glass, без собственных фонов у тулбара и сайдбара.
- Цвета только `Geist.*` или системные стили; отступы и скругления только `Space.*` и `Radius.*`.
- Машинные данные моноширинным шрифтом, меняющиеся числа `.monospacedDigit()` и `.contentTransition(.numericText())`.
- Статус = значок + цвет + текст, никогда не один цвет.
- Термины из `GLOSSARY.md`: Server, Agent, Snapshot, Process, Container, Terminal, Inspector.
