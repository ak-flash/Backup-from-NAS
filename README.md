# Backup from NAS

Универсальный скрипт для резервного копирования данных с NAS. По умолчанию сохраняет бэкап на внешний USB-диск, но опционально может сохранять в любую папку на этом ПК (без USB). Immich — это только один из примеров использования.

## Пример: Бэкап Immich

| Папка | Описание |
|-------|----------|
| `backups/` | Дампы БД Immich (создаются автоматически самим Immich) |
| `upload/` | Загруженные фото/видео (оригиналы) |
| `library/` | Библиотека Immich |
| `external-library/` | Внешняя библиотека |

Источник: `\\FILESERVER\Data\Photo\` → USB-диск в папку `Immich-Backup\`

## Зачем нужен этот скрипт

Скрипт создавался, чтобы упростить регулярное резервное копирование данных с сетевого хранилища (NAS) — например, фотобиблиотеки Immich, документов и других важных файлов — на внешний носитель или в локальную папку. Вместо ручного копирования и сверки файлов он делает всё автоматически: сам выбирает диск, копирует только изменения, при необходимости проверяет целостность данных и ведёт подробный лог. Это снимает рутину и снижает риск ошибки человека при еженедельном/ежемесячном бэкапе.

## Преимущества

- **Инкрементальная синхронизация** — используется `robocopy /MIR`, поэтому копируются только новые и изменённые файлы, а лишние удаляются. Это экономит время и место на диске.
- **Гибкость назначения** — бэкап можно сохранять как на USB-диск (выбор интерактивно или по букве из `-Drive`), так и в любую папку на ПК (локальный режим `-LocalPath` / `local_target_path`, без USB).
- **Проверка целостности (опционально)** — режим `-Verify` считает SHA256-хеши и сравнивает источник с бэкапом, чтобы убедиться, что данные не повреждены при копировании.
- **Наглядный прогресс** — в реальном времени показываются количество файлов, объём, скорость и прошедшее время копирования.
- **Автоочистка** — старые дампы БД и логи удаляются по настроенному сроку хранения (`dump_retention_days`, `log_retention_days`), место не забивается.
- **Полностью настраивается через `config.json`** — ничего не нужно менять в коде: пути, папки, расширения для проверки и сроки хранения задаются в конфигурационном файле.
- **Логирование с ротацией** — подробный журнал каждого запуска, который автоматически ротируется при превышении заданного размера.

## Требования

- Windows 10/11 с PowerShell 5.1+
- Доступ к NAS по сети
- Внешний USB-диск (HDD/SSD) — **только если** не используется локальный режим (`local_target_path`)

## Запуск

### Базовый бэкап (интерактивный выбор USB-диска)
```powershell
.\backup-from-NAS.ps1
```

### Указать букву диска
```powershell
.\backup-from-NAS.ps1 -Drive H
```

### С проверкой целостности (SHA256)
```powershell
.\backup-from-NAS.ps1 -Verify
```

### Всё вместе
```powershell
.\backup-from-NAS.ps1 -Drive H -Verify
```

### Бэкап в локальную папку (без USB)
Вместо USB-диска можно сохранять бэкап в любую папку на этом ПК — через параметр `-LocalPath` или настройку `local_target_path` в `config.json`:
```powershell
# Через параметр
.\backup-from-NAS.ps1 -LocalPath "D:\MyBackups"

# Через config.json (local_target_path заполнен) — параметр не нужен
.\backup-from-NAS.ps1
```
Если `local_target_path` заполнен (или передан `-LocalPath`), USB-диск не требуется и шаг выбора диска пропускается.

## Как это работает

```
[1/4] Выбор назначения
      → локальный режим (local_target_path / -LocalPath) ИЛИ
      → выбор USB-диска (интерактивно или по букве из -Drive / config)

[2/4] Проверка источника
      → проверяет доступность источника и каждой папки

[3/4] Синхронизация (robocopy /MIR)
      → инкрементальная — копирует только изменённые файлы
      → многопоточная (8 потоков)

[3.5] CRC-проверка (только с -Verify)
      → SHA256-хеши для указанной папки
      → сравнение источника и бэкапа

[4/4] Очистка + итог
      → удаляет старые файлы (настраивается)
      → выводит отчёт
```

## Настройки

Все настройки находятся в `config.json`:

| Параметр | По умолчанию | Описание |
|---------|-------------|----------|
| `source_path` | `\\FILESERVER\Data\Photo` | Путь к источнику (NAS) |
| `usb_drive_letter` | `""` | Буква USB-диска (если пусто — интерактивный выбор) |
| `usb_target_folder` | `Immich-Backup` | Имя папки на USB |
| `local_target_path` | `""` | Локальная папка на ПК для бэкапа (если заполнено — USB не используется) |
| `backup_subfolder` | `null` | Подпапка для синхронизируемых папок (опционально) |
| `sync_folders` | массив | Список папок для синхронизации (source → destination) |
| `verify_extensions` | массив | Расширения для CRC-проверки |
| `dump_retention_days` | `30` | Сколько дней хранить старые файлы в папке `backups` |
| `verify` | `false` | Включить проверку целостности по умолчанию |
| `count_files_on_check` | `false` | Подсчитывать количество файлов при проверке источника (медленно) |
| `show_robocopy_progress` | `true` | Показывать прогресс копирования |
| `logs_folder` | `logs` | Имя папки для логов на USB |
| `log_max_size_mb` | `10` | Максимальный размер лог-файла (в МБ), после которого происходит ротация |
| `log_retention_days` | `90` | Сколько дней хранить старые логи |



## Пример config.json для Immich

```json
{
  "source_path": "\\\\FILESERVER\\Data\\Photo",
  "usb_drive_letter": "",
  "usb_target_folder": "Immich-Backup",
  "local_target_path": "",
  "backup_subfolder": "backup",
  "sync_folders": [
    {"source": "backups", "destination": "backups"},
    {"source": "upload", "destination": "upload"},
    {"source": "library", "destination": "library"},
    {"source": "external-library", "destination": "external-library"}
  ],
  "verify_extensions": ["*.jpg", "*.jpeg", "*.png", "*.heic", "*.mp4", "*.mov", "*.gif", "*.dng", "*.arw", "*.cr2", "*.webp", "*.avif", "*.tiff", "*.bmp", "*.raf", "*.nef"],
  "dump_retention_days": 30,
  "verify": false,
  "count_files_on_check": false,
  "show_robocopy_progress": true,
  "logs_folder": "logs",
  "log_max_size_mb": 10,
  "log_retention_days": 90
}
```

## Пример config.json для документов

```json
{
  "source_path": "\\\\FILESERVER\\Data\\Documents",
  "usb_drive_letter": "H",
  "usb_target_folder": "Documents-Backup",
  "local_target_path": "",
  "backup_subfolder": "backup",
  "sync_folders": [
    {"source": "Work", "destination": "Work"},
    {"source": "Personal", "destination": "Personal"},
    {"source": "Archive", "destination": "Archive"}
  ],
  "verify_extensions": ["*.pdf", "*.docx", "*.xlsx", "*.pptx", "*.txt"],
  "dump_retention_days": 90,
  "verify": true,
  "count_files_on_check": false,
  "show_robocopy_progress": true,
  "logs_folder": "logs",
  "log_max_size_mb": 10,
  "log_retention_days": 90
}
```

## Структура бэкапа

```
H:\Immich-Backup\          (USB-режим)
или
D:\MyBackups\              (локальный режим: local_target_path / -LocalPath)
├── backup\               # Синхронизируемые папки
│   ├── backups\          # Дампы БД
│   ├── upload\           # Файлы из источника
│   ├── library\          # Другой пример
│   └── external-library\ # Ещё один пример
├── logs\                 # Логи
│   ├── backup-log.txt
│   ├── backup-log-2026-06-28-12-00-00.txt
│   ├── robocopy-upload.log
│   ├── robocopy-library.log
│   ├── robocopy-backups.log
│   └── robocopy-external-library.log
├── verify\               # Хеши и результаты проверки
│   ├── source-hash-2026-06-28.txt
│   ├── backup-hash-2026-06-28.txt
│   └── diff-2026-06-28.txt
```
