#!/usr/bin/env julia

using Couchzilla
using Base.Test

username = ENV["COUCH_USER"]
password = ENV["COUCH_PASS"]
host     = ENV["COUCH_HOST_URL"]

geo_database = ""
if haskey(ENV, "COUCH_GEO_DATABASE")
  geo_database = ENV["COUCH_GEO_DATABASE"]
end

database = "juliatest-$(Base.Random.uuid4())"
geo_database = "crimes"
cl = Client(username, password, host)
db, created = createdb(cl, database=database)

test_handler(r::Test.Success) = nothing
function test_handler(r::Test.Failure)
  deletedb(cl, database)
  error("Test failed: $(r.expr)")
end

function test_handler(r::Test.Error)
  deletedb(cl, database)
  rethrow(r)
end

Test.with_handler(test_handler) do
  print("[  ] Create test database: $database")
  @test created == true
  println("\r[OK] Create test database: $database")
end

Test.with_handler(test_handler) do
  print("[  ] Read a non-existing id ")
  @test_throws HTTPException readdoc(db, "this-id-does-not-exist")
  println("\r[OK] Read a non-existing id")
end

Test.with_handler(test_handler) do
  print("[  ] Create new doc ")
  data = createdoc(db, Dict("item" => "flange", "location" => "under-stairs cupboard"))
  @test haskey(data, "id")
  @test haskey(data, "rev")
  println("\r[OK] Create new doc")

  print("[  ] Read new doc by {id, rev} (note: bad idea usually) ")
  doc = readdoc(db, data["id"]; rev=data["rev"])
  @test haskey(doc, "item")
  @test doc["item"] == "flange"
  println("\r[OK] Read new doc by {id, rev} (note: bad idea usually)")

  print("[  ] Reading doc by id and bad rev should fail ")
  @test_throws HTTPException readdoc(db, data["id"]; rev="3-63453748494907")
  println("\r[OK] Reading doc by id and bad rev should fail")
  
  print("[  ] Update existing doc ")
  doc = updatedoc(db; id=data["id"], rev=data["rev"], body=Dict("item" => "flange", "location" => "garage"))
  @test haskey(doc, "rev")
  @test contains(doc["rev"], "2-")
  println("\r[OK] Update existing doc")
end

Test.with_handler(test_handler) do
  print("[  ] Create a json Mango index ")
  result = mango_index(db; fields=["data", "data2"])
  @test result["result"] == "created"
  println("\r[OK] Create a json Mango index")
  
  print("[  ] Bulk load data ")
  data=[
      Dict("name"=>"adam",    "data"=>"hello",              "data2" => "television"),
      Dict("name"=>"billy",   "data"=>"world",              "data2" => "vocabulary"),
      Dict("name"=>"bob",     "data"=>"world",              "data2" => "organize"),
      Dict("name"=>"cecilia", "data"=>"authenticate",       "data2" => "study"),
      Dict("name"=>"frank",   "data"=>"authenticate",       "data2" => "region"),    
      Dict("name"=>"davina",  "data"=>"cloudant",           "data2" => "research"),
      Dict("name"=>"eric",    "data"=>"blobbyblobbyblobby", "data2" => "knowledge")
  ]
    
  result = createdoc(db; data=data)
  @test length(result) == length(data)
  println("\r[OK] Bulk load data")
    
  print("[  ] Simple Mango query (equality) ")
  result = mango_query(db, q"data = authenticate")
  @test length(result.docs) == 2
  println("\r[OK] Simple Mango query (equality)")
  
  print("[  ] Compound Mango query (and) ")
  result = mango_query(db, and([q"data = world", q"data2 = vocabulary"]))
  @test length(result.docs) == 1
  @test result.docs[1]["name"] == "billy"
  println("\r[OK] Compound Mango query (and)")
  
  print("[  ] Compound Mango query (or) ")
  result = mango_query(db, or([q"data = world", q"data2 = region"]))
  @test length(result.docs) == 3
  println("\r[OK] Compound Mango query (or)")
  
  print("[  ] Create a text Mango index ")
  textindex = mango_index(db; fields=[
    Dict("name" => "cust",  "type" => "string"), 
    Dict("name" => "value", "type" => "string")
  ])
  @test textindex["result"] == "created"
  println("\r[OK] Create a text Mango index")
  
  maxdoc = 102
  createdoc(db; data=[Dict("cust" => "john", "value" => "hello$x") for x=1:maxdoc])
  print("[  ] Mango query with multi-page return ")
  result = mango_query(db, q"cust=john")
  count = length(result.docs)
  while length(result.docs) > 0
    result = mango_query(db, q"cust = john", bookmark=result.bookmark)
    count += length(result.docs)
  end
  @test count == maxdoc
  println("\r[OK] Mango query with multi-page return")

  print("[  ] Multi-page Mango query as a Task ")
  createdoc(db; data=[Dict("data" => "paged", "data2" => "world$x") for x=1:maxdoc])
  total = 0
  for page in @task paged_mango_query(db, q"data = paged"; pagesize=10)
    total += length(page.docs)
  end
  @test total == maxdoc
  println("\r[OK] Multi-page Mango query as a Task ")

  print("[  ] List indexes ")
  result = listindexes(db)
  @test length(result["indexes"]) == 3
  println("\r[OK] List indexes")
  
  print("[  ] Delete Mango index ")
  result = mango_deleteindex(db; ddoc=textindex["id"], name=textindex["name"], indextype="text")
  @test result["ok"] == true
  println("\r[OK] Delete Mango index")
end

Test.with_handler(test_handler) do
  print("[  ] Streaming changes ")
  count = 0
  maxch = 5
  for ch in @task changes_streaming(db; limit=maxch)
    count += 1
  end
  @test count == maxch + 1 # In stream mode, last item is the CouchDB "last_seq" so need to add 1.
  println("\r[OK] Streaming changes")

  print("[  ] Static changes ")
  data = changes(db; limit=maxch)
  @test maxch == length(data["results"]) # In static mode, "last_seq" is a key in the dict.
  println("\r[OK] Static changes")

  print("[  ] revs_diff ")
  fakerev = "2-1f0e2f0d841ba6b7e3d735b870ebeb8c"
  fakerevs = Dict(data["results"][1]["id"] => [data["results"][1]["changes"][1]["rev"], fakerev])
  diff = revs_diff(db; data=fakerevs)
  @test haskey(diff, data["results"][1]["id"])
  @test diff[data["results"][1]["id"]]["missing"][1] == fakerev
  println("\r[OK] revs_diff")

  print("[  ] bulk_get (note: needs CouchDB2 or Cloudant DBNext) ")
  fetchdata = [ 
    Dict{UTF8String, UTF8String}("id" => data["results"][1]["id"], "rev" => data["results"][1]["changes"][1]["rev"]),
  ]
  response = bulk_get(db; data=fetchdata)
  @test length(response["results"]) == 1
  println("\r[OK] bulk_get (note: needs CouchDB2 or Cloudant DBNext)")
end

Test.with_handler(test_handler) do
  print("[  ] Upload attachment (blob mode) ")
  data = createdoc(db, Dict("item" => "screenshot"))
  result = put_attachment(db, data["id"], data["rev"], "test.png", "image/png", "data/test.png")
  @test result["ok"] == true
  println("\r[OK] Upload attachment (blob mode)")
  
  print("[  ] Retrieve attachment (blob mode) ")
  att = get_attachment(db, result["id"], "test.png"; rev=result["rev"])
  open("data/fetched.png", "w") do f
    write(f, att)
  end
  
  md5_fetched = chomp(readall(`md5 -q data/fetched.png`))
  md5_orig = chomp(readall(`md5 -q data/test.png`))
  @test md5_fetched == md5_orig
  rm("data/fetched.png")
  println("\r[OK] Retrieve attachment (blob mode)")
  
  print("[  ] Delete attachment (blob mode) ")
  result = delete_attachment(db, result["id"], result["rev"], "test.png")
  @test result["ok"] == true
  println("\r[OK] Delete attachment (blob mode)")
end

Test.with_handler(test_handler) do
  print("[  ] Create a view ")
  result = view_index(db, "my_ddoc", "my_view", 
  """
  function(doc) {
    if(doc && doc.name) {
      emit(doc.name, 1);
    }
  }""")
  @test result["ok"] == true
  println("\r[OK] Create a view")
  
  print("[  ] Query view ")
  result = view_query(db, "my_ddoc", "my_view"; include_docs=true, key="adam")
  @test length(result["rows"]) == 1
  println("\r[OK] Query view")
  
  print("[  ] Query view (POST)")
  result = view_query(db, "my_ddoc", "my_view"; keys=["adam", "billy"])
  @test length(result["rows"]) == 2
  println("\r[OK] Query view (POST)")
end

Test.with_handler(test_handler) do
  print("[  ] Create a geospatial index ")
  result = geo_index(db, "geodd", "geoidx", 
    "function(doc){if(doc.geometry&&doc.geometry.coordinates){st_index(doc.geometry);}}"
  )
  @test result["ok"] == true
  println("\r[OK] Create a geospatial index")

  print("[  ] Get geospatial index info ")
  result = geo_indexinfo(db, "geodd", "geoidx")
  @test haskey(result, "geo_index") == true
  println("\r[OK] Get geospatial index info")

  if geo_database != ""
    geodb = connectdb(cl, database=geo_database)
    print("[  ] Radius geospatial query ")
    result = geo_query(geodb, "geodd", "geoidx";
      lat    = 42.357963,
      lon    = -71.063991,
      radius = 10000.0,
      limit  = 200)
    
    @test length(result["rows"]) == 200
    println("\r[OK] Radius geospatial query")

    print("[  ] Polygon geospatial query ")
    result = geo_query(geodb, "geodd", "geoidx";
      g="POLYGON ((-71.0537124 42.3681995 0,-71.054399 42.3675178 0,-71.0522962 42.3667409 0,-71.051631 42.3659324 0,-71.051631 42.3621431 0,-71.0502148 42.3618577 0,-71.0505152 42.3660275 0,-71.0511589 42.3670263 0,-71.0537124 42.3681995 0))")
    @test length(result["rows"]) == 2
    println("\r[OK] Polygon geospatial query")
  else 
    println("** Skipping geospatial query tests")
    println("** Replicate https://education.cloudant.com/crimes and set the variable COUCH_GEO_DATABASE")
  end
end

print("[  ] Delete test database: $database ")
result = deletedb(cl, database)
@test result["ok"] == true
println("\r[OK] Delete test database: $database")