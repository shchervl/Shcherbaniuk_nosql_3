"""Конвертація файлів MovieLens 1M (.dat, роздільник '::', Latin-1) у CSV (',', UTF-8).

Запуск з кореня проєкту (один раз перед завантаженням у Neo4j):

    uv run python convert.py                # читає data/ml-1m, пише в import/
    uv run python convert.py <src> <dst>    # інші каталоги

Крім зміни роздільника й кодування скрипт:
  * виносить рік випуску з назви фільму в окрему колонку `year`;
  * розшифровує коди вікової групи та професії (таблиці з README датасету);
  * відкидає поштовий індекс — у графі він не використовується.
"""

import csv
import re
import sys
from pathlib import Path

SRC_ENCODING = "latin-1"
SEP = "::"

# "Toy Story (1995)" -> ("Toy Story", 1995)
TITLE_RE = re.compile(r"^(?P<title>.*)\((?P<year>\d{4})\)$")

AGE_GROUPS = {
    1: "Under 18",
    18: "18-24",
    25: "25-34",
    35: "35-44",
    45: "45-49",
    50: "50-55",
    56: "56+",
}

OCCUPATIONS = {
    0: "other",
    1: "academic/educator",
    2: "artist",
    3: "clerical/admin",
    4: "college/grad student",
    5: "customer service",
    6: "doctor/health care",
    7: "executive/managerial",
    8: "farmer",
    9: "homemaker",
    10: "K-12 student",
    11: "lawyer",
    12: "programmer",
    13: "retired",
    14: "sales/marketing",
    15: "scientist",
    16: "self-employed",
    17: "technician/engineer",
    18: "tradesman/craftsman",
    19: "unemployed",
    20: "writer",
}


def read_dat(path: Path):
    """Повертає рядки .dat-файлу, розбиті за '::'."""
    with path.open(encoding=SRC_ENCODING) as f:
        for line in f:
            line = line.rstrip("\r\n")
            if line:
                yield line.split(SEP)


def write_csv(path: Path, header: list[str], rows) -> int:
    count = 0
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        for row in rows:
            writer.writerow(row)
            count += 1
    return count


def movies(src: Path):
    # movies.dat: MovieID::Title::Genres
    for movie_id, raw_title, genres in read_dat(src / "movies.dat"):
        match = TITLE_RE.match(raw_title.strip())
        if match:
            title, year = match["title"].strip(), match["year"]
        else:  # у ML-1M таких рядків немає, але дані вносилися вручну
            title, year = raw_title.strip(), ""
        yield movie_id, title, year, genres


def users(src: Path):
    # users.dat: UserID::Gender::Age::Occupation::Zip-code
    for user_id, gender, age, occupation, _zip in read_dat(src / "users.dat"):
        yield user_id, gender, age, AGE_GROUPS[int(age)], OCCUPATIONS[int(occupation)]


def ratings(src: Path):
    # ratings.dat: UserID::MovieID::Rating::Timestamp
    yield from read_dat(src / "ratings.dat")


def main() -> None:
    root = Path(__file__).resolve().parent
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "data" / "ml-1m"
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else root / "import"

    if not (src / "movies.dat").exists():
        sys.exit(f"Не знайдено {src / 'movies.dat'} — спершу розпакуйте ml-1m.zip (див. README).")
    dst.mkdir(parents=True, exist_ok=True)

    jobs = [
        ("movies.csv", ["movieId", "title", "year", "genres"], movies(src)),
        ("users.csv", ["userId", "gender", "age", "ageGroup", "occupation"], users(src)),
        ("ratings.csv", ["userId", "movieId", "rating", "timestamp"], ratings(src)),
    ]
    for name, header, rows in jobs:
        count = write_csv(dst / name, header, rows)
        print(f"{name:<12} {count:>9,} рядків -> {dst / name}")


if __name__ == "__main__":
    main()
