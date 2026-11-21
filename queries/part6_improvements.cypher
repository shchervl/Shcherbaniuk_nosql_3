// =====================================================================
// Частина 6.3 (і стратегія з частини 4). Експерименти зі схемою:
// три зміни схеми та вимірювання їхнього ефекту через PROFILE (DbHits).
// Запуск:
//   docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 --format verbose < queries/part6_improvements.cypher
// Останній блок повертає граф до базової схеми з частини 1.
// =====================================================================

// ---------------------------------------------------------------------
// A. Денормалізовані агрегати на вузлі Movie -> запити 1 і 4
// ---------------------------------------------------------------------
// A0. Базовий запит 1 (як у part3.cypher).
PROFILE
MATCH (:Genre {name: 'Thriller'})<-[:HAS_GENRE]-(m:Movie)<-[r:RATED]-(:User)
WITH m, avg(r.rating) AS avgRating, count(r) AS ratings
WHERE avgRating > 4.0
RETURN m.title AS title, m.year AS year, round(avgRating, 2) AS avgRating, ratings
ORDER BY avgRating DESC, ratings DESC;

// A1. Базовий запит 4 (як у part3.cypher, без stdDev і pctHigh).
PROFILE
MATCH (g:Genre)<-[:HAS_GENRE]-(m:Movie)<-[r:RATED]-(:User)
RETURN g.name AS genre, count(DISTINCT m) AS ratedMovies, count(r) AS ratings,
       round(avg(r.rating), 3) AS avgRating
ORDER BY avgRating DESC;

// A2. Зміна схеми: кількість, сума і середнє оцінок зберігаються на фільмі.
MATCH (m:Movie)
OPTIONAL MATCH (m)<-[r:RATED]-(:User)
WITH m, count(r) AS ratingCount, sum(r.rating) AS ratingSum
SET m.ratingCount = ratingCount,
    m.ratingSum   = ratingSum,
    m.avgRating   = CASE WHEN ratingCount > 0 THEN toFloat(ratingSum) / ratingCount END;

// A3. Запит 1 на агрегатах: ребра RATED взагалі не читаються.
PROFILE
MATCH (:Genre {name: 'Thriller'})<-[:HAS_GENRE]-(m:Movie)
WHERE m.avgRating > 4.0
RETURN m.title AS title, m.year AS year, round(m.avgRating, 2) AS avgRating, m.ratingCount AS ratings
ORDER BY avgRating DESC, ratings DESC;

// A4. Запит 4 на агрегатах: середнє жанру = сума сум / сума кількостей.
PROFILE
MATCH (g:Genre)<-[:HAS_GENRE]-(m:Movie)
WHERE m.ratingCount > 0
RETURN g.name AS genre, count(m) AS ratedMovies, sum(m.ratingCount) AS ratings,
       round(toFloat(sum(m.ratingSum)) / sum(m.ratingCount), 3) AS avgRating
ORDER BY avgRating DESC;

// ---------------------------------------------------------------------
// B. Окремий тип ребра LIKED для оцінок >= 4 -> запит 5 (і запит 3)
// ---------------------------------------------------------------------
// B0. Базовий запит 5 (як у part3.cypher).
PROFILE
MATCH (me:User {userId: 1})-[r1:RATED]->(m:Movie)<-[r2:RATED]-(other:User)
WHERE r1.rating >= 4 AND r2.rating >= 4
WITH me, other, count(m) AS common
WHERE common >= 5
WITH me, other, common,
     COUNT { (me)-[x:RATED]->() WHERE x.rating >= 4 } AS myLiked,
     COUNT { (other)-[x:RATED]->() WHERE x.rating >= 4 } AS otherLiked
WITH me, other, toFloat(common) / (myLiked + otherLiked - common) AS similarity
ORDER BY similarity DESC
LIMIT 30
MATCH (other)-[r:RATED]->(rec:Movie)
WHERE r.rating >= 4
  AND NOT EXISTS { (me)-[:RATED]->(rec) }
WITH rec, count(other) AS neighbours, avg(r.rating) AS avgRating, sum(similarity) AS score
WHERE neighbours >= 3
RETURN rec.title AS title, rec.year AS year, neighbours,
       round(avgRating, 2) AS avgRating, round(score, 3) AS score
ORDER BY score DESC, avgRating DESC
LIMIT 10;

// B1. Зміна схеми: кожна оцінка >= 4 дублюється ребром LIKED
//     (батчами по 10 000 через CALL {...} IN TRANSACTIONS).
MATCH (u:User)-[r:RATED]->(m:Movie)
WHERE r.rating >= 4
CALL (u, m, r) {
  MERGE (u)-[l:LIKED]->(m)
  SET l.rating = r.rating
} IN TRANSACTIONS OF 10000 ROWS;

MATCH ()-[l:LIKED]->() RETURN count(l) AS likedRelationships;

// B2. Запит 5 через LIKED: фільтр за властивістю зник, а COUNT { (x)-[:LIKED]->() }
//     читає готовий ступінь вузла за типом ребра замість перебору оцінок.
PROFILE
MATCH (me:User {userId: 1})-[:LIKED]->(m:Movie)<-[:LIKED]-(other:User)
WITH me, other, count(m) AS common
WHERE common >= 5
WITH me, other, common,
     COUNT { (me)-[:LIKED]->() } AS myLiked,
     COUNT { (other)-[:LIKED]->() } AS otherLiked
WITH me, other, toFloat(common) / (myLiked + otherLiked - common) AS similarity
ORDER BY similarity DESC
LIMIT 30
MATCH (other)-[l:LIKED]->(rec:Movie)
WHERE NOT EXISTS { (me)-[:RATED]->(rec) }
WITH rec, count(other) AS neighbours, avg(l.rating) AS avgRating, sum(similarity) AS score
WHERE neighbours >= 3
RETURN rec.title AS title, rec.year AS year, neighbours,
       round(avgRating, 2) AS avgRating, round(score, 3) AS score
ORDER BY score DESC, avgRating DESC
LIMIT 10;

// ---------------------------------------------------------------------
// C. Індекс на властивості ребра RATED.rating -> запит 2
// ---------------------------------------------------------------------
// C0. Базовий запит 2 (як у part3.cypher).
PROFILE
MATCH (u:User)-[r:RATED {rating: 5}]->(:Movie)
WITH u, count(r) AS fives
WHERE fives > 50
RETURN u.userId AS userId, fives
ORDER BY fives DESC
LIMIT 10;

// C1. Зміна схеми: range-індекс на властивості ребра.
CREATE INDEX rated_rating IF NOT EXISTS
FOR ()-[r:RATED]-() ON (r.rating);

CALL db.awaitIndexes(300);

// C2. Той самий запит 2 — тепер планувальник може стартувати з індексу ребер.
PROFILE
MATCH (u:User)-[r:RATED {rating: 5}]->(:Movie)
WITH u, count(r) AS fives
WHERE fives > 50
RETURN u.userId AS userId, fives
ORDER BY fives DESC
LIMIT 10;

// ---------------------------------------------------------------------
// D. Повернення до базової схеми
// ---------------------------------------------------------------------
DROP INDEX rated_rating IF EXISTS;

MATCH ()-[l:LIKED]->()
CALL (l) {
  DELETE l
} IN TRANSACTIONS OF 10000 ROWS;

MATCH (m:Movie)
REMOVE m.ratingCount, m.ratingSum, m.avgRating;
