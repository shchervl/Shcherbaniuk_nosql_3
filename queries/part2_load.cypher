// =====================================================================
// Частина 2. Індекси та завантаження даних MovieLens 1M
// Запуск:
//   docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 < queries/part2_load.cypher
// Скрипт ідемпотентний: повторний запуск не створює дублів.
// =====================================================================

// ---------------------------------------------------------------------
// 1. Обмеження унікальності та індекси.
//    Створюються ДО завантаження: кожне обмеження UNIQUE автоматично
//    будує range-індекс, тож MERGE/MATCH за ключем — це пошук в індексі,
//    а не перебір усіх вузлів мітки.
// ---------------------------------------------------------------------
CREATE CONSTRAINT user_id IF NOT EXISTS
FOR (u:User) REQUIRE u.userId IS UNIQUE;

CREATE CONSTRAINT movie_id IF NOT EXISTS
FOR (m:Movie) REQUIRE m.movieId IS UNIQUE;

CREATE CONSTRAINT genre_name IF NOT EXISTS
FOR (g:Genre) REQUIRE g.name IS UNIQUE;

// Пошук фільму за назвою — типова точка входу в граф.
CREATE INDEX movie_title IF NOT EXISTS
FOR (m:Movie) ON (m.title);

// Чекаємо, доки всі індекси перейдуть у стан ONLINE.
CALL db.awaitIndexes(300);

// ---------------------------------------------------------------------
// 2. Вузли User (6 040)
// ---------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///users.csv' AS row
MERGE (u:User {userId: toInteger(row.userId)})
SET u.gender     = row.gender,
    u.age        = toInteger(row.age),
    u.ageGroup   = row.ageGroup,
    u.occupation = row.occupation;

// ---------------------------------------------------------------------
// 3. Вузли Movie (3 883), вузли Genre (18) і ребра HAS_GENRE (6 408)
// ---------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///movies.csv' AS row
MERGE (m:Movie {movieId: toInteger(row.movieId)})
SET m.title = row.title,
    m.year  = toInteger(row.year)
WITH m, row
UNWIND split(row.genres, '|') AS genreName
MERGE (g:Genre {name: genreName})
MERGE (m)-[:HAS_GENRE]->(g);

// ---------------------------------------------------------------------
// 4. Ребра RATED (1 000 209) — батчами по 10 000 рядків.
//    Вузли вже існують, тому в тілі лише MATCH за індексованим ключем;
//    MERGE ребра захищає від дублів при повторному запуску.
// ---------------------------------------------------------------------
CALL apoc.periodic.iterate(
  "LOAD CSV WITH HEADERS FROM 'file:///ratings.csv' AS row RETURN row",
  "MATCH (u:User  {userId:  toInteger(row.userId)})
   MATCH (m:Movie {movieId: toInteger(row.movieId)})
   MERGE (u)-[r:RATED]->(m)
   SET r.rating    = toInteger(row.rating),
       r.timestamp = toInteger(row.timestamp)",
  {batchSize: 10000, parallel: false}
)
YIELD batches, total, committedOperations, failedOperations, errorMessages, timeTaken
RETURN batches, total, committedOperations, failedOperations, errorMessages, timeTaken;

// ---------------------------------------------------------------------
// 5. Перевірка результату
// ---------------------------------------------------------------------
MATCH (u:User) RETURN count(u) AS users;
MATCH (m:Movie) RETURN count(m) AS movies;
MATCH (g:Genre) RETURN count(g) AS genres;
MATCH ()-[r:HAS_GENRE]->() RETURN count(r) AS movieGenres;
MATCH ()-[r:RATED]->() RETURN count(r) AS ratings;

// Дублі: пари (користувач, фільм) з більш ніж одним ребром RATED — має бути 0.
MATCH (u:User)-[r:RATED]->(m:Movie)
WITH u, m, count(r) AS rels
WHERE rels > 1
RETURN count(*) AS duplicatedRatings;

// Індекси та обмеження, що існують у базі.
SHOW INDEXES YIELD name, type, entityType, labelsOrTypes, properties, state
WHERE type <> 'LOOKUP'
RETURN name, type, entityType, labelsOrTypes, properties, state;
