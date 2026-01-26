name := "scala-example"
version := "0.1.0"
scalaVersion := "3.8.1"

enablePlugins(JavaAppPackaging)

libraryDependencies ++= Seq(
  "org.http4s" %% "http4s-ember-server" % "0.23.24",
  "org.http4s" %% "http4s-dsl" % "0.23.24",
  "org.typelevel" %% "cats-effect" % "3.5.2"
)

Compile / mainClass := Some("Main")
