// Offscreen renderer for the omavoice overlay previews and render tests.
// Loads a QML harness into a QQuickView that is never shown and grabs each
// frame with QQuickWindow::grabWindow(), which renders on the GPU through
// QRhi without mapping a window. Nothing appears on screen.
//
// Usage: render <harness.qml> <outdir> <frames> [key=value ...]
// The key=value pairs reach QML as the `renderArgs` context property. Each
// frame calls the root's step(i) and prints the string it returns.
#include <QGuiApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickView>
#include <QDir>
#include <QImage>
#include <QVariantMap>
#include <cstdio>

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s harness.qml outdir frames [key=value ...]\n", argv[0]);
    return 2;
  }
  QGuiApplication app(argc, argv);
  QVariantMap args;
  for (int i = 4; i < argc; i++) {
    QString kv = QString::fromLocal8Bit(argv[i]);
    int eq = kv.indexOf('=');
    if (eq > 0) args.insert(kv.left(eq), kv.mid(eq + 1));
  }
  QQuickView view;
  view.setColor(Qt::transparent);
  view.rootContext()->setContextProperty("renderArgs", args);
  view.setResizeMode(QQuickView::SizeViewToRootObject);
  view.setSource(QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1])));
  if (view.status() != QQuickView::Ready || !view.rootObject()) {
    for (const auto &e : view.errors()) fprintf(stderr, "%s\n", qPrintable(e.toString()));
    return 1;
  }
  QDir().mkpath(QString::fromLocal8Bit(argv[2]));
  const int frames = atoi(argv[3]);
  QQuickItem *root = view.rootObject();
  for (int i = 0; i < frames; i++) {
    QVariant meta;
    QMetaObject::invokeMethod(root, "step", Q_RETURN_ARG(QVariant, meta), Q_ARG(QVariant, i));
    QImage img = view.grabWindow();
    if (img.isNull()) {
      fprintf(stderr, "grab failed at frame %d\n", i);
      return 1;
    }
    img.save(QString("%1/frame_%2.png").arg(QString::fromLocal8Bit(argv[2])).arg(i, 5, 10, QChar('0')));
    printf("%s\n", qPrintable(meta.toString()));
    fflush(stdout);
  }
  const int api = view.rendererInterface() ? int(view.rendererInterface()->graphicsApi()) : -1;
  fprintf(stderr, "rendered %d frames, graphics api %d, %dx%d\n", frames, api, view.width(), view.height());
  return 0;
}
