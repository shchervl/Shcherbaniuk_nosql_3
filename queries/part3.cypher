// =====================================================================
// Частина 3. Запити різної складності
// Запуск:
//   docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 < queries/part3.cypher
// =====================================================================

// ---------------------------------------------------------------------
// Запит 1. Фільми жанру «Thriller» із середнім рейтингом вище 4.0
// ---------------------------------------------------------------------
MATCH (:Genre {name: 'Thriller'})<-[:HAS_GENRE]-(m:Movie)<-[r:RATED]-(:User)
WITH m, avg(r.rating) AS avgRating, count(r) AS ratings
WHERE avgRating > 4.0
RETURN m.title AS title, m.year AS year, round(avgRating, 2) AS avgRating, ratings
ORDER BY avgRating DESC, ratings DESC;

// ---------------------------------------------------------------------
// Запит 2. Користувачі, які поставили оцінку 5 більш ніж 50 фільмам
// ---------------------------------------------------------------------
MATCH (u:User)-[r:RATED {rating: 5}]->(:Movie)
WITH u, count(r) AS fives
WHERE fives > 50
RETURN u.userId AS userId, u.gender AS gender, u.ageGroup AS ageGroup,
       u.occupation AS occupation, fives
ORDER BY fives DESC;

// ---------------------------------------------------------------------
// Запит 3. Фільми, які обидва користувачі (userId = 1 і userId = 2)
//          оцінили високо (рейтинг >= 4)
// ---------------------------------------------------------------------
MATCH (u1:User {userId: 1})-[r1:RATED]->(m:Movie)<-[r2:RATED]-(u2:User {userId: 2})
WHERE r1.rating >= 4 AND r2.rating >= 4
RETURN m.title AS title, m.year AS year, r1.rating AS user1, r2.rating AS user2
ORDER BY r1.rating + r2.rating DESC, title;

// ---------------------------------------------------------------------
// Запит 4. Жанри, чиї фільми стабільно отримують високі оцінки:
//          середній рейтинг, кількість оцінок, розкид і частка оцінок >= 4
// ---------------------------------------------------------------------
MATCH (g:Genre)<-[:HAS_GENRE]-(m:Movie)<-[r:RATED]-(:User)
RETURN g.name AS genre,
       count(DISTINCT m) AS ratedMovies,
       count(r) AS ratings,
       round(avg(r.rating), 3) AS avgRating,
       round(stDev(r.rating), 3) AS stdDev,
       round(100.0 * sum(CASE WHEN r.rating >= 4 THEN 1 ELSE 0 END) / count(r), 1) AS pctHigh
ORDER BY avgRating DESC;

// ---------------------------------------------------------------------
// Запит 5. Рекомендація «користувачі зі схожими смаками також дивилися»
//          для userId = 1 (колаборативна фільтрація user-based):
//   1) шукаємо користувачів, які високо оцінили ті самі фільми;
//   2) схожість = коефіцієнт Жаккара множин уподобаних фільмів;
//   3) беремо 30 найсхожіших сусідів;
//   4) радимо фільми, які вони оцінили високо, а користувач ще не бачив.
// ---------------------------------------------------------------------
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

// ---------------------------------------------------------------------
// Запит 6. Найкоротший ланцюжок між двома користувачами через спільні фільми
// ---------------------------------------------------------------------
// 6a. Користувачі 1 і 2 мають спільні фільми -> шлях довжини 2.
MATCH p = shortestPath((u1:User {userId: 1})-[:RATED*..10]-(u2:User {userId: 2}))
RETURN [n IN nodes(p) | coalesce(n.title, 'User ' + toString(n.userId))] AS chain,
       length(p) AS hops;

// 6b. Користувачі 1 і 46 не мають жодного спільного фільму -> шлях довжини 4.
MATCH p = shortestPath((u1:User {userId: 1})-[:RATED*..10]-(u2:User {userId: 46}))
RETURN [n IN nodes(p) | coalesce(n.title, 'User ' + toString(n.userId))] AS chain,
       length(p) AS hops;

// 6c. Розподіл довжин найкоротших шляхів від користувача 1 до всіх інших.
MATCH (u1:User {userId: 1})
MATCH (u2:User)
WHERE u2 <> u1
MATCH p = shortestPath((u1)-[:RATED*..10]-(u2))
RETURN length(p) AS hops, count(*) AS users
ORDER BY hops;
