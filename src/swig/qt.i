// SPDX-License-Identifier: GPL-3.0-or-later

// Make the base classes look like "complete"

%nodefaultctor QObject;
class QObject {};

%nodefaultctor QThread;
class QThread {};

%nodefaultctor QList;
template <class T>
class QList {
public:
  int length() const;
  T at(int i) const;
};

%template(SPlayerList) QList<ServerPlayer *>;
%template(IntList) QList<int>;

%native(GetMicroSecond) int GetMicroSecond(lua_State *L);
%{
#include <sys/time.h>
static int GetMicroSecond(lua_State *L) {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  long long microsecond = (long long)tv.tv_sec * 1000000 + tv.tv_usec;
  lua_pushnumber(L, microsecond);
  return 1;
}
%}

%native(fkHttpPost) int fkHttpPost(lua_State *L);
%{
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QEventLoop>
// 同步 HTTP POST，返回 (body, http_code, err)
static int fkHttpPost(lua_State *L) {
  int argc = lua_gettop(L);
  if (argc < 2 || !lua_isstring(L, 1) || !lua_isstring(L, 2)) {
    return luaL_error(L, "fkHttpPost expects (url, body[, timeout_ms])");
  }
  const QByteArray url = QByteArray(lua_tostring(L, 1));
  const QByteArray body = QByteArray(lua_tostring(L, 2));
  int timeoutMs = 30000;
  if (argc >= 3 && lua_isnumber(L, 3)) timeoutMs = (int)lua_tointeger(L, 3);
  QNetworkAccessManager manager;
  manager.setTransferTimeout(timeoutMs);
  QNetworkRequest request{QUrl(QString::fromUtf8(url))};
  request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
  if (argc >= 4 && lua_isstring(L, 4)) {
    const QByteArray bearer = QByteArray(lua_tostring(L, 4));
    if (!bearer.isEmpty()) {
      request.setRawHeader("Authorization", "Bearer " + bearer);
    }
  }
  QNetworkReply *reply = manager.post(request, body);
  QEventLoop loop;
  QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
  loop.exec();
  const QByteArray data = reply->readAll();
  const int code = reply->attribute(
      QNetworkRequest::HttpStatusCodeAttribute).toInt();
  const QString err = reply->error() == QNetworkReply::NoError
      ? QString() : reply->errorString();
  reply->deleteLater();
  lua_pushlstring(L, data.constData(), data.size());
  lua_pushinteger(L, code);
  lua_pushstring(L, err.toUtf8().constData());
  return 3;
}
%}
void qDebug(const char *msg, ...);
void qInfo(const char *msg, ...);
void qWarning(const char *msg, ...);
void qCritical(const char *msg, ...);

class QJsonDocument {
public:
  enum JsonFormat {
    Indented,
    Compact,
  };
  static QJsonDocument fromJson(const QByteArray &json);
  static QJsonDocument fromVariant(const QVariant &variant);
  QByteArray toJson(QJsonDocument::JsonFormat format = 1) const;
  QVariant toVariant() const;
};

class QRandomGenerator {
public:
  QRandomGenerator(unsigned int seed = 1);
  unsigned int generate();
  unsigned int bounded(unsigned int lowest, unsigned int highest);
};

%extend QRandomGenerator {
  QVariant random(int low = -1, int high = -1) {
    QVariant ret;
    if (high < 0) {
      if (low < 1) {
        ret.setValue(qreal($self->bounded(0, 100000001)) / 100000000);
      } else {
        ret.setValue($self->bounded(1, low + 1));
      }
    } else {
      ret.setValue($self->bounded(low, high + 1));
    }
    return ret;
  }
}

%native(addQmlImportPath) int addQmlImportPath(lua_State *L);
%{
static int addQmlImportPath(lua_State *L) {
  int argc = lua_gettop(L);
  if (argc != 1 || !lua_isstring(L, 1)) {
    return luaL_error(L, "addQmlImportPath expects 1 string argument");
  }

  const char *path = lua_tostring(L, 1);

  auto engine = Backend->getEngine();
  auto list = engine->importPathList();
  list << path;
  engine->setImportPathList(list);

  return 0;
}
%}

