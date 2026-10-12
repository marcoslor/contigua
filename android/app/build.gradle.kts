plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.pocketdeck"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.pocketdeck"
        minSdk = 30
        targetSdk = 36
        // Shizuku user-service version: it is the daemon's version marker, so it
        // must be bumped on every install or the previously-bound service keeps
        // running instead of being replaced.
        versionCode = 2
        versionName = "0.1.0"
    }

    buildFeatures {
        aidl = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    sourceSets {
        getByName("test") {
            // The C4 loopback harness is a plain JVM main() living in the test
            // source set; it only touches proto/ + the JVM-testable session core.
        }
    }
}

dependencies {
    // Shizuku: run server/ as shell (UID 2000) with no hidden-API restrictions.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("androidx.core:core-ktx:1.13.1")

    testImplementation("junit:junit:4.13.2")
}

// Runs the C4 harness (see tools/fakephone/deckctl.py) on the JVM with the same
// classpath as the unit tests. Prints "PORT=<n>" once it is listening.
val c4Harness by tasks.registering(JavaExec::class) {
    group = "verification"
    description = "Start the loopback protocol harness for interop testing with deckctl.py"
    dependsOn("compileDebugUnitTestKotlin")
    val ownClasses = files(
        layout.buildDirectory.dir("tmp/kotlin-classes/debug"),
        layout.buildDirectory.dir("tmp/kotlin-classes/debugUnitTest"),
        layout.buildDirectory.dir("intermediates/javac/debug/compileDebugJavaWithJavac/classes"),
    )
    classpath = configurations.getByName("debugUnitTestRuntimeClasspath") + ownClasses
    mainClass.set("dev.pocketdeck.c4.C4Harness")
    // Forward -Pc4args="..." to main().
    (project.findProperty("c4args") as String?)?.let { args = it.split(" ") }
}
