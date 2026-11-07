#include "secrets.h"
#include <ArduinoJson.h>
#include <DHT.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <time.h>

// ---- Cấu hình thiết bị ----
constexpr uint8_t DHT_PIN = 4;
constexpr uint8_t DHT_TYPE = DHT22;
constexpr char SITE[] = "home";
constexpr char DEVICE_ID[] = "dev01";
constexpr uint32_t TELEMETRY_INTERVAL_MS = 2000; // DHT22 tối thiểu ~2s/lần
constexpr uint32_t WIFI_RETRY_MS = 15000;
constexpr uint32_t MQTT_RETRY_MIN_MS = 2000;
constexpr uint32_t MQTT_RETRY_MAX_MS = 30000;
constexpr time_t TIME_VALID_AFTER = 1700000000; // epoch hợp lệ (sau 11/2023)

DHT dht(DHT_PIN, DHT_TYPE);
WiFiClient net;
PubSubClient mqtt(net);

char topicTelemetry[80];
char topicStatus[80];
char clientId[40];

constexpr uint8_t FAN_PIN = 5;
constexpr bool FAN_ACTIVE_HIGH =
    true; // module relay kích mức thấp thì đổi thành false

bool fanOn = false;
char topicCmd[80];
char topicAck[80];
char lastCmdId[40] = ""; // chống thực hiện lặp lệnh

uint32_t lastTelemetry = 0, lastWifiTry = 0, lastMqttTry = 0;
uint32_t mqttRetryDelay = MQTT_RETRY_MIN_MS;
uint32_t seq = 0; // số thứ tự bản tin, dùng phát hiện mất gói

bool timeSynced() { return time(nullptr) > TIME_VALID_AFTER; }

void ensureWifi() {
  if (WiFi.status() == WL_CONNECTED)
    return;
  if (millis() - lastWifiTry < WIFI_RETRY_MS && lastWifiTry != 0)
    return;
  lastWifiTry = millis();
  Serial.println("[WiFi] connecting...");
  WiFi.disconnect();
  WiFi.begin(WIFI_SSID, WIFI_PASS);
}

void ensureMqtt() {
  if (WiFi.status() != WL_CONNECTED || mqtt.connected())
    return;
  if (millis() - lastMqttTry < mqttRetryDelay && lastMqttTry != 0)
    return;
  lastMqttTry = millis();

  Serial.printf("[MQTT] connecting to %s:%d ...\n", MQTT_HOST, MQTT_PORT);
  const char *willMsg = "{\"v\":1,\"state\":\"offline\"}";
  // connect(id, user, pass, willTopic, willQos, willRetain, willMessage)
  if (mqtt.connect(clientId, MQTT_USER, MQTT_PASS, topicStatus, 1, true,
                   willMsg)) {
    Serial.println("[MQTT] connected");
    mqtt.publish(topicStatus, "{\"v\":1,\"state\":\"online\"}",
                 true);          // retained
    mqtt.subscribe(topicCmd, 1); // QoS 1
    mqttRetryDelay = MQTT_RETRY_MIN_MS;
  } else {
    Serial.printf("[MQTT] failed, rc=%d\n", mqtt.state());
    mqttRetryDelay = min(mqttRetryDelay * 2, MQTT_RETRY_MAX_MS); // backoff
  }
}

void setFan(bool on) {
  fanOn = on;
  digitalWrite(FAN_PIN, (on == FAN_ACTIVE_HIGH) ? HIGH : LOW);
}

void publishAck(const char *cmdId, const char *status, const char *reason) {
  JsonDocument doc;
  doc["v"] = 1;
  doc["device_id"] = DEVICE_ID;
  doc["cmd_id"] = cmdId;
  doc["status"] = status; // ok | error | expired
  if (reason)
    doc["reason"] = reason;
  doc["fan"] = fanOn ? "on" : "off"; // trạng thái thật của thiết bị
  doc["ts"] = (uint32_t)time(nullptr);
  char buf[220];
  size_t n = serializeJson(doc, buf, sizeof(buf));
  mqtt.publish(topicAck, (const uint8_t *)buf, n, false);
}

void onMqttMessage(char *topic, byte *payload, unsigned int len) {
  JsonDocument doc;
  if (deserializeJson(doc, payload, len)) {
    publishAck("", "error", "bad_json");
    return;
  }
  // Copy hết ra biến cục bộ TRƯỚC khi publish (xem lưu ý bên dưới)
  char cmdId[40], action[16], value[8];
  strlcpy(cmdId, doc["cmd_id"] | "", sizeof(cmdId));
  strlcpy(action, doc["action"] | "", sizeof(action));
  strlcpy(value, doc["value"] | "", sizeof(value));
  int ver = doc["v"] | 0;
  uint32_t ts = doc["ts"] | 0;
  uint32_t ttl = doc["ttl_s"] | 30;

  if (ver != 1 || cmdId[0] == '\0') {
    publishAck(cmdId, "error", "bad_cmd");
    return;
  }
  if (strcmp(cmdId, lastCmdId) == 0) {
    publishAck(cmdId, "ok", "duplicate");
    return;
  }
  if (ts > 0 && timeSynced() && (uint32_t)time(nullptr) > ts + ttl) {
    publishAck(cmdId, "expired", nullptr);
    return;
  }
  if (strcmp(action, "fan") != 0 ||
      (strcmp(value, "on") != 0 && strcmp(value, "off") != 0)) {
    publishAck(cmdId, "error", "unsupported");
    return;
  }
  setFan(strcmp(value, "on") == 0);
  strlcpy(lastCmdId, cmdId, sizeof(lastCmdId));
  publishAck(cmdId, "ok", nullptr);
}

void publishTelemetry() {
  float t = dht.readTemperature();
  float h = dht.readHumidity();
  if (isnan(t) || isnan(h)) {
    Serial.println("[DHT] read failed");
    return;
  }
  JsonDocument doc; // ArduinoJson 7.x
  doc["v"] = 1;
  doc["device_id"] = DEVICE_ID;
  doc["ts"] = (uint32_t)time(nullptr); // epoch giây, UTC
  doc["seq"] = seq++;
  doc["temp_c"] = round(t * 10) / 10.0;
  doc["hum_pct"] = round(h * 10) / 10.0;
  doc["fan"] = fanOn ? "on" : "off";

  char buf[200];
  size_t n = serializeJson(doc, buf, sizeof(buf));
  bool ok = mqtt.publish(topicTelemetry, (const uint8_t *)buf, n, false);
  Serial.printf("[PUB] %s -> %s\n", ok ? "ok" : "FAIL", buf);
}

void setup() {
  Serial.begin(115200);
  delay(500);
  snprintf(topicTelemetry, sizeof(topicTelemetry), "iot/v1/%s/%s/telemetry",
           SITE, DEVICE_ID);
  snprintf(topicStatus, sizeof(topicStatus), "iot/v1/%s/%s/status", SITE,
           DEVICE_ID);
  snprintf(clientId, sizeof(clientId), "episense-%s", DEVICE_ID);
  snprintf(topicCmd, sizeof(topicCmd), "iot/v1/%s/%s/cmd", SITE,
           DEVICE_ID); // thêm
  snprintf(topicAck, sizeof(topicAck), "iot/v1/%s/%s/ack", SITE,
           DEVICE_ID); // thêm

  pinMode(FAN_PIN, OUTPUT); // thêm
  setFan(false);            // thêm: mặc định tắt khi khởi động

  dht.begin();
  WiFi.mode(WIFI_STA);
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  configTime(0, 0, "pool.ntp.org", "time.google.com"); // UTC
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setKeepAlive(15);
  mqtt.setSocketTimeout(5);
  mqtt.setCallback(onMqttMessage); // thêm
  mqtt.setBufferSize(512);         // thêm: mặc định 256 byte là sát giới hạn
}

void loop() {
  ensureWifi();
  ensureMqtt();
  mqtt.loop(); // giữ keep-alive, bắt buộc gọi thường xuyên

  if (mqtt.connected() && timeSynced() &&
      millis() - lastTelemetry >= TELEMETRY_INTERVAL_MS) {
    lastTelemetry = millis();
    publishTelemetry();
  }
}