ThisBuild / scalaVersion := "2.13.12"
ThisBuild / version := "0.1.0"
ThisBuild / organization := "pararisc"
val chiselVersion = "6.5.0"
libraryDependencies += "org.chipsalliance" %% "chisel" % chiselVersion
addCompilerPlugin("org.chipsalliance" % "chisel-plugin" % chiselVersion cross CrossVersion.full)
scalacOptions ++= Seq("-deprecation", "-feature", "-unchecked", "-language:reflectiveCalls")
Compile / run / fork := true
Compile / mainClass := Some("tier2.Generate")
