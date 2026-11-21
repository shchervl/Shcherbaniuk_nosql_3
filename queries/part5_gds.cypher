// =====================================================================
// Частина 5 (додаткова). Графові алгоритми через GDS:
// PageRank, Louvain, Dijkstra
// Запуск (увесь файл виконується близько 5 хвилин):
//   docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 --format verbose < queries/part5_gds.cypher
// Блоки «прибирання» повертають граф до базової схеми з частини 1.
// =====================================================================


// =====================================================================
// 5.1. PageRank на графі фільмів
// =====================================================================

// Крок 1: матеріалізуємо ребра фільм-фільм через спільних користувачів.
// Вага ребра = кількість користувачів, які оцінили обидва фільми на 4-5.
// Беремо 50 000 найсильніших пар серед фільмів, що мають понад 20 оцінок.
// elementId(m1) < elementId(m2) залишає кожну невпорядковану пару один раз
// (у завданні тут id(), але в Neo4j 2026 ця функція позначена як застаріла).
MATCH (m1:Movie)<-[r1:RATED]-(u:User)-[r2:RATED]->(m2:Movie)
WHERE r1.rating >= 4 AND r2.rating >= 4 AND elementId(m1) < elementId(m2)
WITH m1, m2, count(u) AS weight
WHERE COUNT { (m1)<-[:RATED]-() } > 20
  AND COUNT { (m2)<-[:RATED]-() } > 20
WITH m1, m2, weight
ORDER BY weight DESC
LIMIT 50000
MERGE (m1)-[co:CO_RATED]-(m2)
SET co.weight = weight;

// Крок 2: проєкція в пам'ять GDS на основі матеріалізованих ребер.
CALL gds.graph.project(
  'movieGraph',
  'Movie',
  { CO_RATED: { orientation: 'UNDIRECTED', properties: 'weight' } }
)
YIELD graphName, nodeCount, relationshipCount
RETURN graphName, nodeCount, relationshipCount;

// Крок 3а: зважений PageRank, топ-20 фільмів.
// Поруч — кількість оцінок, кількість оцінок 4-5 і середній рейтинг,
// щоб порівняти PageRank зі звичайною популярністю.
CALL gds.pageRank.stream('movieGraph', {
  relationshipWeightProperty: 'weight',
  dampingFactor: 0.85,
  maxIterations: 100
})
YIELD nodeId, score
WITH gds.util.asNode(nodeId) AS m, score
ORDER BY score DESC
LIMIT 20
MATCH (m)<-[r:RATED]-(:User)
RETURN m.title AS title, m.year AS year, round(score, 2) AS pageRank,
       count(r) AS ratings,
       sum(CASE WHEN r.rating >= 4 THEN 1 ELSE 0 END) AS likes,
       round(avg(r.rating), 2) AS avgRating
ORDER BY pageRank DESC;

// Крок 3б: записуємо PageRank у властивість вузла, щоб порівняти ранги.
CALL gds.pageRank.write('movieGraph', {
  relationshipWeightProperty: 'weight',
  dampingFactor: 0.85,
  maxIterations: 100,
  writeProperty: 'pagerank'
})
YIELD nodePropertiesWritten, ranIterations, didConverge
RETURN nodePropertiesWritten, ranIterations, didConverge;

// Ранг за популярністю (кількість оцінок) і ранг за PageRank — тимчасові властивості.
MATCH (m:Movie)
WITH m, COUNT { (m)<-[:RATED]-() } AS ratings
ORDER BY ratings DESC
WITH collect(m) AS movies
UNWIND range(0, size(movies) - 1) AS i
WITH movies[i] AS m, i + 1 AS position
SET m.popularityRank = position;

MATCH (m:Movie)
WITH m
ORDER BY m.pagerank DESC
WITH collect(m) AS movies
UNWIND range(0, size(movies) - 1) AS i
WITH movies[i] AS m, i + 1 AS position
SET m.pagerankRank = position;

// Наскільки PageRank повторює інші показники: кореляції для фільмів, що мають ребра CO_RATED.
// strength = сума ваг ребер CO_RATED вузла (зважений ступінь).
MATCH (m:Movie)
WHERE EXISTS { (m)-[:CO_RATED]-() }
MATCH (m)-[co:CO_RATED]-()
WITH m, sum(co.weight) AS strength
MATCH (m)<-[r:RATED]-(:User)
WITH m, strength, count(r) AS ratings,
     sum(CASE WHEN r.rating >= 4 THEN 1 ELSE 0 END) AS likes, avg(r.rating) AS avgRating
WITH collect(m.pagerank) AS pr, collect(toFloat(strength)) AS strength,
     collect(toFloat(ratings)) AS ratings, collect(toFloat(likes)) AS likes,
     collect(avgRating) AS avgRating
RETURN size(pr) AS movies,
       round(gds.similarity.pearson(pr, strength), 3)  AS corrWeightedDegree,
       round(gds.similarity.pearson(pr, likes), 3)     AS corrLikes,
       round(gds.similarity.pearson(pr, ratings), 3)   AS corrRatings,
       round(gds.similarity.pearson(pr, avgRating), 3) AS corrAvgRating;

// Популярні фільми, які PageRank опускає найсильніше (серед топ-100 за кількістю оцінок).
MATCH (m:Movie)
WHERE m.popularityRank <= 100
MATCH (m)<-[r:RATED]-(:User)
WITH m, count(r) AS ratings, round(avg(r.rating), 2) AS avgRating
RETURN m.title AS title, m.popularityRank AS popularityRank, m.pagerankRank AS pagerankRank,
       m.popularityRank - m.pagerankRank AS shift, ratings, avgRating
ORDER BY shift ASC
LIMIT 10;

// Фільми, які PageRank піднімає найсильніше (серед топ-100 за PageRank).
MATCH (m:Movie)
WHERE m.pagerankRank <= 100
MATCH (m)<-[r:RATED]-(:User)
WITH m, count(r) AS ratings, round(avg(r.rating), 2) AS avgRating
RETURN m.title AS title, m.popularityRank AS popularityRank, m.pagerankRank AS pagerankRank,
       m.popularityRank - m.pagerankRank AS shift, ratings, avgRating
ORDER BY shift DESC
LIMIT 10;

// Візуалізація (Neo4j Browser): 15 фільмів з найвищим PageRank і зв'язки між ними.
MATCH (m:Movie)
WHERE m.pagerankRank <= 15
WITH collect(m) AS top
MATCH (a:Movie)-[co:CO_RATED]-(b:Movie)
WHERE a IN top AND b IN top AND a.movieId < b.movieId
RETURN count(co) AS edgesAmongTop15;
// у Browser замість останнього рядка: RETURN a, co, b

// ----- 5.1: прибирання -----
// Крок 4: видаляємо проєкцію, тимчасові ребра і властивості.
CALL gds.graph.drop('movieGraph') YIELD graphName RETURN graphName AS dropped;
MATCH ()-[co:CO_RATED]-() DELETE co;
MATCH (m:Movie) REMOVE m.pagerank, m.popularityRank, m.pagerankRank;


// =====================================================================
// 5.2. Виявлення спільнот (Louvain)
// =====================================================================

// Крок 1: матеріалізуємо ребра користувач-користувач через спільні фільми.
// weight = кількість фільмів, які обидва оцінили на 4-5;
// cost = 1 / weight — «довжина» ребра для Дейкстри з пункту 5.3
//        (що більше спільних фільмів, то ближчі користувачі).
// Агрегація виконується окремо для кожного u1 у підзапиті CALL: у пам'яті
// одночасно лежать сусіди лише одного користувача, а не всі ~18 млн пар.
MATCH (u1:User)
CALL (u1) {
  MATCH (u1)-[r1:RATED]->(m:Movie)<-[r2:RATED]-(u2:User)
  WHERE r1.rating >= 4 AND r2.rating >= 4 AND u1.userId < u2.userId
  RETURN u2, count(m) AS weight
}
WITH u1, u2, weight
ORDER BY weight DESC
LIMIT 50000
MERGE (u1)-[sim:SIMILAR]-(u2)
SET sim.weight = weight,
    sim.cost   = 1.0 / weight;

// Скільки користувачів узагалі потрапило в граф схожості.
MATCH ()-[s:SIMILAR]->()
WITH count(s) AS edges, min(s.weight) AS minWeight, max(s.weight) AS maxWeight
MATCH (u:User)
WHERE EXISTS { (u)-[:SIMILAR]-() }
RETURN edges, minWeight, maxWeight, count(u) AS connectedUsers;

// Крок 2: проєкція (одна на пункти 5.2 і 5.3).
CALL gds.graph.project(
  'userSimilarity',
  'User',
  { SIMILAR: { orientation: 'UNDIRECTED', properties: ['weight', 'cost'] } }
)
YIELD graphName, nodeCount, relationshipCount
RETURN graphName, nodeCount, relationshipCount;

// Крок 3: Louvain; номер спільноти записується у властивість User.community.
// concurrency: 1 робить результат відтворюваним: у паралельному режимі Louvain
// недетермінований, і на цьому графі від запуску до запуску виходить то 3, то 4 спільноти.
CALL gds.louvain.write('userSimilarity', {
  relationshipWeightProperty: 'weight',
  writeProperty: 'community',
  concurrency: 1
})
YIELD communityCount, modularity, ranLevels
RETURN communityCount, round(modularity, 4) AS modularity, ranLevels;

// 10 найбільших кластерів.
MATCH (u:User)
RETURN u.community AS community, count(*) AS users
ORDER BY users DESC
LIMIT 10;

// Розподіл користувачів за розміром кластера.
MATCH (u:User)
WITH u.community AS community, count(*) AS users
RETURN CASE WHEN users = 1 THEN '1 (ізольований вузол)'
            WHEN users < 10 THEN '2-9'
            ELSE '10+' END AS clusterSize,
       count(*) AS clusters, sum(users) AS users
ORDER BY clusterSize;

// Крок 4а: три найпопулярніші жанри кожної спільноти
// (за кількістю оцінок 4-5, поставлених її учасниками).
MATCH (u:User)
WITH u.community AS community, collect(u) AS members
WHERE size(members) >= 10
UNWIND members AS u
MATCH (u)-[r:RATED]->(:Movie)-[:HAS_GENRE]->(g:Genre)
WHERE r.rating >= 4
WITH community, size(members) AS users, g.name AS genre, count(*) AS likes
ORDER BY likes DESC
WITH community, users, collect(genre + ' ' + toString(likes)) AS genres
RETURN community, users, genres[..3] AS top3Genres
ORDER BY users DESC;

// Крок 4б: ті самі жанри відносно «середнього глядача».
// lift = частка жанру серед уподобань спільноти / частка жанру серед уподобань усіх користувачів.
MATCH (:User)-[r:RATED]->(:Movie)-[:HAS_GENRE]->(g:Genre)
WHERE r.rating >= 4
WITH g.name AS genre, count(*) AS likes
WITH collect({genre: genre, likes: likes}) AS rows, sum(likes) AS total
WITH { x IN rows | x.genre: toFloat(x.likes) / total } AS globalShare
MATCH (u:User)
WITH globalShare, u.community AS community, collect(u) AS members
WHERE size(members) >= 10
UNWIND members AS u
MATCH (u)-[r:RATED]->(:Movie)-[:HAS_GENRE]->(g:Genre)
WHERE r.rating >= 4
WITH globalShare, community, size(members) AS users, g.name AS genre, count(*) AS likes
WITH globalShare, community, users, collect({genre: genre, likes: likes}) AS rows, sum(likes) AS total
UNWIND rows AS x
WITH community, users, x.genre AS genre,
     round(toFloat(x.likes) / total / globalShare[x.genre], 2) AS lift
ORDER BY lift DESC
WITH community, users, collect(genre + ' x' + toString(lift)) AS genres
RETURN community, users, genres[..4] AS overRepresented, reverse(genres)[..3] AS underRepresented
ORDER BY users DESC;

// Крок 4в: найхарактерніші фільми спільноти — ті, що її учасники вподобали
// значно частіше, ніж усі користувачі графа схожості (мінімум 25% учасників).
MATCH (u:User)
WITH u.community AS community, collect(u) AS members
WHERE size(members) >= 10
WITH collect({community: community, members: members}) AS clusters, sum(size(members)) AS clustered
UNWIND clusters AS c
UNWIND c.members AS u
MATCH (u)-[r:RATED]->(m:Movie)
WHERE r.rating >= 4
WITH clustered, c.community AS community, size(c.members) AS users, m, count(*) AS likesInCluster
WHERE likesInCluster >= users * 0.25
MATCH (m)<-[r2:RATED]-(v:User)
WHERE r2.rating >= 4 AND EXISTS { (v)-[:SIMILAR]-() }
WITH clustered, community, users, m, likesInCluster, count(*) AS likesAll
WITH community, users, m,
     round((toFloat(likesInCluster) / users) / (toFloat(likesAll) / clustered), 2) AS lift
ORDER BY lift DESC
WITH community, users, collect(m.title + ' (' + toString(m.year) + ') x' + toString(lift)) AS movies
RETURN community, users, movies[..6] AS typicalMovies
ORDER BY users DESC;

// Крок 4г: демографія й активність спільнот.
MATCH (u:User)
WITH u.community AS community, collect(u) AS members
WHERE size(members) >= 10
UNWIND members AS u
MATCH (u)-[r:RATED]->(m:Movie)
WITH community, u, count(r) AS rated,
     sum(CASE WHEN r.rating >= 4 THEN 1 ELSE 0 END) AS liked, avg(m.year) AS movieYear
RETURN community, count(u) AS users,
       round(100.0 * sum(CASE WHEN u.gender = 'M' THEN 1 ELSE 0 END) / count(u), 1) AS pctMale,
       round(avg(u.age), 1) AS avgAgeGroupStart,
       round(avg(rated)) AS avgRated,
       round(avg(liked)) AS avgLiked,
       round(avg(movieYear), 1) AS avgMovieYear
ORDER BY users DESC;

// Крок 4ґ: будова спільнот у графі схожості — середній ступінь, частка зв'язків
// усередині своєї спільноти і кількість «листків» (користувачів з одним ребром).
MATCH (u:User)-[:SIMILAR]-(v:User)
WITH u, count(v) AS degree,
     sum(CASE WHEN v.community = u.community THEN 1 ELSE 0 END) AS inside
RETURN u.community AS community, count(*) AS users,
       round(avg(degree), 1) AS avgDegree,
       round(avg(toFloat(inside) / degree), 2) AS avgInsideShare,
       sum(CASE WHEN degree = 1 THEN 1 ELSE 0 END) AS leaves
ORDER BY users DESC;

// Візуалізація (Neo4j Browser): тимчасові мітки Community1..N (за спаданням розміру),
// щоб Browser розфарбував спільноти різними кольорами.
MATCH (u:User)
WITH u.community AS community, collect(u) AS members
WHERE size(members) >= 10
WITH community, members
ORDER BY size(members) DESC
WITH collect(members) AS clusters
UNWIND range(0, size(clusters) - 1) AS i
UNWIND clusters[i] AS u
SET u:$('Community' + toString(i + 1));

// По 14 найтиповіших учасників кожної спільноти (ступінь 40-200, найбільша частка
// зв'язків усередині своєї спільноти) і всі ребра SIMILAR між ними.
MATCH (u:User)-[:SIMILAR]-(v:User)
WITH u, count(v) AS degree,
     sum(CASE WHEN v.community = u.community THEN 1 ELSE 0 END) AS inside
WHERE degree >= 40 AND degree <= 200
WITH u, toFloat(inside) / degree AS insideShare
ORDER BY insideShare DESC
WITH u.community AS community, collect(u)[..14] AS core
WITH coll.flatten(collect(core)) AS sample
MATCH (a:User)-[s:SIMILAR]-(b:User)
WHERE a IN sample AND b IN sample AND a.userId < b.userId
RETURN count(s) AS edgesInSample,
       sum(CASE WHEN a.community = b.community THEN 1 ELSE 0 END) AS insideCommunity;
// у Browser замість останніх двох рядків: RETURN a, s, b


// =====================================================================
// 5.3. Найкоротший шлях між користувачами (Dijkstra)
// Використовується проєкція userSimilarity з пункту 5.2.
// =====================================================================

// Дейкстра за вагою cost = 1 / (кількість спільних уподобаних фільмів):
// найкоротший шлях — це ланцюжок найсхожіших між собою користувачів.
UNWIND [[4277, 4344], [2918, 3715], [6011, 3610], [5981, 3796], [3610, 3796], [5981, 6001]] AS pair
MATCH (source:User {userId: pair[0]})
MATCH (target:User {userId: pair[1]})
CALL gds.shortestPath.dijkstra.stream('userSimilarity', {
  sourceNode: source,
  targetNode: target,
  relationshipWeightProperty: 'cost'
})
YIELD totalCost, nodeIds, costs
WITH pair, totalCost, costs, [id IN nodeIds | gds.util.asNode(id).userId] AS path
RETURN pair, path,
       size(path) - 1 AS hops,
       size(path) - 2 AS intermediateUsers,
       [i IN range(1, size(costs) - 1) | toInteger(round(1.0 / (costs[i] - costs[i - 1])))] AS commonMovies,
       round(totalCost, 4) AS totalCost;

// Розподіл довжин найкоротших шляхів (у хопах) між усіма парами користувачів графа схожості
// та середня довжина шляху.
CALL gds.allShortestPaths.stream('userSimilarity')
YIELD sourceNodeId, targetNodeId, distance
WHERE sourceNodeId < targetNodeId
WITH toInteger(distance) AS hops, count(*) AS pairs
ORDER BY hops
WITH collect({hops: hops, pairs: pairs}) AS rows, sum(pairs) AS total, sum(hops * pairs) AS totalHops
UNWIND rows AS row
RETURN row.hops AS hops, row.pairs AS pairs,
       round(100.0 * row.pairs / total, 1) AS pct,
       round(toFloat(totalHops) / total, 3) AS avgPathLength;

// Хаби: скільки користувачів графа схожості напряму пов'язані з найзв'язанішими вузлами.
MATCH (u:User)
WHERE EXISTS { (u)-[:SIMILAR]-() }
WITH u, COUNT { (u)-[:SIMILAR]-() } AS degree
RETURN u.userId AS userId, degree, COUNT { (u)-[:RATED]->() } AS ratings
ORDER BY degree DESC
LIMIT 5;

// Візуалізація (Neo4j Browser): шлях Дейкстри між користувачами 5981 і 3796.
MATCH (source:User {userId: 5981})
MATCH (target:User {userId: 3796})
CALL gds.shortestPath.dijkstra.stream('userSimilarity', {
  sourceNode: source,
  targetNode: target,
  relationshipWeightProperty: 'cost'
})
YIELD nodeIds
WITH [id IN nodeIds | gds.util.asNode(id)] AS users
UNWIND range(0, size(users) - 2) AS i
WITH users[i] AS a, users[i + 1] AS b
MATCH (a)-[s:SIMILAR]-(b)
RETURN a.userId AS fromUser, b.userId AS toUser, s.weight AS commonMovies;
// у Browser замість останнього рядка: RETURN a, s, b

// ----- 5.2-5.3: прибирання -----
// Крок 5: видаляємо проєкцію, тимчасові ребра, властивості й мітки.
CALL gds.graph.drop('userSimilarity') YIELD graphName RETURN graphName AS dropped;
MATCH ()-[sim:SIMILAR]-() DELETE sim;
MATCH (u:User) REMOVE u.community;
MATCH (u:User)
WHERE size(labels(u)) > 1
WITH u, [l IN labels(u) WHERE l STARTS WITH 'Community'] AS extra
REMOVE u:$(extra);
