# 07: MasshCore: монитор доступности

**What to build:** Монитор отдаёт поток статусов Online / Offline / Unknown для каждого Server: TCP-подключение к SSH-порту с таймаутом 3 с, проверка сразу, каждые 30 с и при пробуждении Mac. Server за Bastion проверяется через существующее ControlMaster-соединение с Bastion (`ssh -W`), без него — Unknown.

**Blocked by:** 05

**Status:** done

- [x] Открытый порт → Online, закрытый/фильтруемый → Offline не позже 3 с (тесты на локальных сокетах)
- [x] Проверки по таймеру 30 с и по событию пробуждения
- [x] Server с ProxyJump при живом соединении с Bastion проверяется через него
- [x] Server с ProxyJump без соединения с Bastion → Unknown
- [x] Статус не зависит от Agent
