import std/[
  locks,
  parsecfg,
  strformat,
  strutils,
  sugar,
  tables,
  times,
]
from std/unicode import nil
import db_connector/db_sqlite
import mummy, mummy/routers
import webby

proc getUsers(config: Config): Table[string, string] =
  let data = config.getSectionValue("", "users")
  for mapping in data.split(','):
    let kv = mapping.split(':')
    result[kv[0].strip()] = kv[1].strip()

let
  globalConfig = loadConfig("config.ini")
  users = globalConfig.getUsers()
  db = open("receipts.db", "", "", "")

var
  L: Lock
  config {.threadvar.}: Config

initLock(L)

proc getUser(fromNumber: string): string =
  {.gcsafe.}:
    try:
      users[fromNumber]
    except KeyError:
      ""

proc newReceipt(user, smsId, message: string; smsTimestamp: DateTime): string =
  let messageSplit = message.strip().rsplit(maxsplit=1)
  if messageSplit.len < 2:
    return "Behöver ett namn och summa!"

  let
    receiptName = messageSplit[0]
    amount =
      try:
         (messageSplit[1].replace(',', '.').parseFloat * 100).toInt
      except ValueError:
        return "Förstod inte summan, den måste vara ett heltal eller decimaltal."

  {.gcsafe.}:
    withLock L:
      db.exec(sql"""INSERT INTO receipts
                      (smsId, timestamp, user, name, amount)
                    VALUES
                      (?, ?, ?, ?, ?)
                    """,
              smsId, smsTimestamp, user, receiptName, amount)

  result = "Sparat!"

proc mark(user, smsId: string; smsTimestamp: DateTime): string =
  {.gcsafe.}:
    withLock L:
      db.exec(sql"INSERT INTO mark (sms_id, timestamp, user) VALUES (?, ?, ?)",
              smsId, smsTimestamp, user)
  result = "Stängde perioden."

proc sum(): string =
  var sums: seq[Row]
  {.gcsafe.}:
    withLock L:
      sums = db.getAllRows(sql"""SELECT user, sum(amount) FROM receipts
                                 WHERE timestamp >= (
                                   SELECT coalesce(max(timestamp), "1970-01-01T00:00:00Z") FROM mark
                                 )
                                 GROUP BY user""")
  let sumStrs = collect:
    for row in sums:
      let
        user = row[0]
        sum = row[1].parseFloat / 100
      fmt"{user}: {sum}"
  result = sumStrs.join("\n")
  echo result

proc newSms(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    withLock L:
      config = globalConfig

  let
    data = request.body.parseSearch()
    now = now().utc
    smsTimestamp = data["created"].parse("yyyy-MM-dd hh:mm:ss'.'ffffff", tz=utc())
    smsId = data["id"]
    fromNumber = data["from"]
    toNumber = data["to"]
    message = data["message"]
    user = getUser(fromNumber)

  {.gcsafe.}:
    withLock L:
      try:
        db.exec(sql"""INSERT INTO sms
                        (cb_timestamp, sms_timestamp, sms_id, from_number, to_number, message)
                      VALUES
                        (?, ?, ?, ?, ?, ?)
                      """,
                now, smsTimestamp, smsId, fromNumber, toNumber, message)
      except:
        stderr.writeLine(getCurrentExceptionMsg())
        request.respond(204)
        return

  if message.startsWith('!'):
    var cmd = message.strip(trailing = false, chars = {'!'}).strip()
    cmd = unicode.toLower(cmd)
    echo cmd == "stäng"
    if cmd == "stäng":
      let response = mark(user, smsId, smsTimestamp)
      request.respond(200, body = response)
    elif cmd == "summa":
      let response = sum()
      request.respond(200, body = response)
  else:
    let response = newReceipt(user, smsId, message, smsTimestamp)
    request.respond(200, body = response)

when isMainModule:
  db.exec(sql"""CREATE TABLE IF NOT EXISTS sms (
                  cb_timestamp TEXT,
                  sms_timestamp TEXT,
                  sms_id TEXT UNIQUE,
                  from_number TEXT,
                  to_number TEXT,
                  message TEXT
                )""")

  db.exec(sql"""CREATE TABLE IF NOT EXISTS receipts (
                  sms_id TEXT,
                  timestamp TEXT,
                  user TEXT,
                  name TEXT,
                  amount INTEGER
                )""")

  db.exec(sql"""CREATE TABLE IF NOT EXISTS mark (
                  sms_id TEXT,
                  timestamp TEXT,
                  user TEXT
                )""")

  var router: Router
  router.post("/new-sms", newSms)

  let
    hostname = globalConfig.getSectionValue("", "hostname")
    port = globalConfig.getSectionValue("", "port").parseInt()
    server = newServer(router)

  echo fmt"Serving on http://{hostname}:{port}"
  server.serve(Port(port), address = hostname)
