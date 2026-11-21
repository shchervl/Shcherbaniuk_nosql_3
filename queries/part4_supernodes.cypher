// =====================================================================
// Частина 4. Виявлення супервузлів
// Запуск (verbose-формат потрібен, щоб побачити плани PROFILE і DbHits):
//   docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 --format verbose < queries/part4_supernodes.cypher
// =====================================================================

// ---------------------------------------------------------------------
// 4.1. Розподіл ступенів вузлів за мітками: що таке «звичайний» вузол
//      і наскільки від нього відхиляється максимум.
// ---------------------------------------------------------------------
MATCH (n)
WITH labels(n)[0] AS label, COUNT { (n)--() } AS degree
RETURN label,
       count(*) AS nodes,
       min(degree) AS minDegree,
       round(avg(degree), 1) AS avgDegree,
       toInteger(percentileCont(degree, 0.5)) AS median,
       toInteger(percentileCont(degree, 0.99)) AS p99,
       max(degree) AS maxDegree
ORDER BY label;

// ---------------------------------------------------------------------
// 4.2. Вузли з аномально великою кількістю ребер — топ-15 у всьому графі.
//      COUNT { (n)--() } без фільтрів читає ступінь із запису вузла,
//      а не перебирає ребра, тому запит дешевий навіть для супервузлів.
// ---------------------------------------------------------------------
MATCH (n)
WITH n, labels(n)[0] AS label, COUNT { (n)--() } AS degree
RETURN label,
       coalesce(n.title, n.name, 'User ' + toString(n.userId)) AS node,
       degree
ORDER BY degree DESC
LIMIT 15;

// ---------------------------------------------------------------------
// 4.3. Найактивніші користувачі (супервузли з боку User).
// ---------------------------------------------------------------------
MATCH (u:User)
WITH u, COUNT { (u)-[:RATED]->() } AS ratings
RETURN u.userId AS userId, u.gender AS gender, u.ageGroup AS ageGroup,
       u.occupation AS occupation, ratings
ORDER BY ratings DESC
LIMIT 10;

// ---------------------------------------------------------------------
// 4.4. Жанрові вузли: скільки фільмів «висить» на кожному
//      і яку частку всіх фільмів він покриває.
// ---------------------------------------------------------------------
MATCH (m:Movie)
WITH count(m) AS totalMovies
MATCH (g:Genre)
WITH g, totalMovies, COUNT { (g)<-[:HAS_GENRE]-() } AS movies
RETURN g.name AS genre, movies, round(100.0 * movies / totalMovies, 1) AS pctOfMovies
ORDER BY movies DESC;

// ---------------------------------------------------------------------
// 4.5. Концентрація: яка частка всіх оцінок припадає на 1% і 10%
//      найпопулярніших фільмів.
// ---------------------------------------------------------------------
MATCH (m:Movie)
WITH m, COUNT { (m)<-[:RATED]-() } AS degree
ORDER BY degree DESC
WITH collect(degree) AS degrees, sum(degree) AS total
WITH degrees, total,
     toInteger(ceil(size(degrees) * 0.01)) AS top1,
     toInteger(ceil(size(degrees) * 0.10)) AS top10
RETURN total AS ratings,
       top1 AS moviesInTop1pct,
       round(100.0 * reduce(s = 0, d IN degrees[..top1] | s + d) / total, 1) AS pctRatingsTop1pct,
       top10 AS moviesInTop10pct,
       round(100.0 * reduce(s = 0, d IN degrees[..top10] | s + d) / total, 1) AS pctRatingsTop10pct;

// ---------------------------------------------------------------------
// 4.6. Вплив на продуктивність: той самий запит «що ще оцінювали глядачі
//      цього фільму» для супервузла і для звичайного вузла.
//      Обидва фільми знаходяться за індексом movie_id за 2 звернення,
//      різниця виникає лише на етапі розгортання ребер (Expand).
// ---------------------------------------------------------------------
// Супервузол: American Beauty (movieId = 2858), 3 428 оцінок.
PROFILE
MATCH (m:Movie {movieId: 2858})<-[:RATED]-(u:User)-[:RATED]->(other:Movie)
RETURN m.title AS movie, count(*) AS paths, count(DISTINCT other) AS otherMovies;

// Звичайний вузол: All the King's Men (movieId = 1942), 119 оцінок (близько до медіани).
PROFILE
MATCH (m:Movie {movieId: 1942})<-[:RATED]-(u:User)-[:RATED]->(other:Movie)
RETURN m.title AS movie, count(*) AS paths, count(DISTINCT other) AS otherMovies;

// ---------------------------------------------------------------------
// 4.7. Фільтр за властивістю ребра на супервузлі: щоб знайти 83 оцінки «1»,
//      доводиться прочитати властивість кожного з 3 428 ребер.
// ---------------------------------------------------------------------
PROFILE
MATCH (m:Movie {movieId: 2858})<-[r:RATED]-(u:User)
WHERE r.rating = 1
RETURN m.title AS movie, count(u) AS usersRatedOne;
