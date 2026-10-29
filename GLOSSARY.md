# massh

massh — SSH-клиент для macOS, который помимо терминала показывает состояние Linux-серверов: доступность, сервисы, контейнеры, порты и ресурсы.

## Language

### Серверы

**Server**:
Удалённая Linux-машина, описанная блоком `Host` в `~/.ssh/config`; идентифицируется именем этого блока.
_Avoid_: Host (как термин приложения), машина, нода

**Server List**:
Перечень всех Server, которые видит пользователь при выборе, к кому подключиться.
_Avoid_: Hosts, inventory

**Online / Offline / Unknown**:
Online — SSH-порт Server принимает TCP-соединения (для Server за Bastion — проверка идёт через Bastion); Offline — не принимает; Unknown — проверить нельзя, потому что с Bastion нет соединения.
_Avoid_: Up/down, alive, reachable

**Bastion**:
Server, через который идёт подключение к другому Server (директива `ProxyJump`).
_Avoid_: Jump host, proxy, gateway

### Наблюдение

**Agent**:
Постоянно работающая программа massh на Server, которая собирает сведения о нём и транслирует их приложению в реальном времени.
_Avoid_: Daemon, collector, exporter

**Process**:
Пользовательская программа, запущенная на Server вне контейнеров; системные тоже считаются, потоки ядра — нет.
_Avoid_: Service, task

**Container**:
Запущенный Docker-контейнер на Server вместе с его потреблением CPU и памяти и занятыми портами.
_Avoid_: Docker app, pod

**Snapshot**:
Полное состояние Server в один момент: обзор системы, порты, Process и Container вместе.
_Avoid_: Metrics, report, stats

### Окно

**Terminal**:
Режим окна, в котором справа от Server List открыты терминальные вкладки к Server.
_Avoid_: Консоль, shell-панель

**Inspector**:
Режим окна, в котором справа от Server List на всю ширину показано состояние выбранного Server по его Snapshot.
_Avoid_: Информационная панель, дашборд, правая колонка
