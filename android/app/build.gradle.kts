plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
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
        versionCode = 125
        versionName = "0.1.0"
    }

    buildFeatures {
        aidl = true
        buildConfig = true
        compose = true
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

    testOptions {
        unitTests {
            // Robolectric needs the merged resources and manifest.
            isIncludeAndroidResources = true
        }
    }

    lint {
        // The reviewed shell-process code (server/) has three pre-existing
        // NewApi findings that are out of this task's scope; they are recorded
        // here so genuine new issues still fail the build.
        baseline = file("lint-baseline.xml")
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    // Shizuku: run server/ as shell (UID 2000) with no hidden-API restrictions.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("androidx.core:core-ktx:1.13.1")

    // Compose + Material 3 (versions from the BOM).
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    // QR scanning (the pair flow's consent step).
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")

    testImplementation("junit:junit:4.13.2")

    // JVM screenshot tests: Robolectric + Roborazzi.
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core-ktx:1.6.1")
    testImplementation("androidx.test.ext:junit:1.2.1")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.32.2")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.32.2")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// Screenshot tests record PNGs into app/src/test/screenshots (commit-ready).
tasks.withType<Test>().configureEach {
    systemProperty("roborazzi.test.record", "true")
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
