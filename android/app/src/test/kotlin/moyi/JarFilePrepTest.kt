package moyi

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class JarFilePrepTest {

    private fun tempJar(content: String): File {
        val file = Files.createTempFile("jarprep", ".jar").toFile()
        file.writeText(content)
        file.deleteOnExit()
        return file
    }

    @Test
    fun sealForLoadMakesFileReadOnly() {
        val file = tempJar("dex-bytes")
        assertTrue(JarFilePrep.isWritable(file))
        JarFilePrep.sealForLoad(file)
        assertFalse(JarFilePrep.isWritable(file))
        assertEquals("dex-bytes", file.readText())
    }

    @Test
    fun sealForLoadIsIdempotent() {
        val file = tempJar("dex-bytes")
        JarFilePrep.sealForLoad(file)
        JarFilePrep.sealForLoad(file)
        assertFalse(JarFilePrep.isWritable(file))
    }

    @Test
    fun sealForLoadMissingFileThrows() {
        val missing = File("definitely-missing-" + System.nanoTime() + ".jar")
        val error = assertThrows(IllegalStateException::class.java) {
            JarFilePrep.sealForLoad(missing)
        }
        assertTrue(error.message.orEmpty().contains("不存在"))
    }

    @Test
    fun makeWritableRestoresWriteAfterSeal() {
        val file = tempJar("v1")
        JarFilePrep.sealForLoad(file)
        assertFalse(JarFilePrep.isWritable(file))
        JarFilePrep.makeWritable(file)
        assertTrue(JarFilePrep.isWritable(file))
        file.writeText("v2")
        assertEquals("v2", file.readText())
    }

    @Test
    fun replaceTargetSwapsContentAndSeals() {
        val dir = Files.createTempDirectory("jarprep").toFile()
        val target = File(dir, "site.jar")
        target.writeText("old")
        JarFilePrep.sealForLoad(target)
        val temp = File(dir, "site.jar.part")
        temp.writeText("new")
        JarFilePrep.replaceTarget(temp, target)
        assertFalse(temp.exists())
        assertEquals("new", target.readText())
        assertFalse(JarFilePrep.isWritable(target))
    }

    @Test
    fun replaceTargetRoundTripsRepeatedly() {
        val dir = Files.createTempDirectory("jarprep").toFile()
        val target = File(dir, "site.jar")
        target.writeText("v0")
        JarFilePrep.sealForLoad(target)
        for (version in 1..3) {
            val temp = File(dir, "site.jar.part")
            temp.writeText("v$version")
            JarFilePrep.replaceTarget(temp, target)
            assertEquals("v$version", target.readText())
            assertFalse(JarFilePrep.isWritable(target))
        }
    }

    @Test
    fun replaceTargetCreatesSealedFileWhenTargetAbsent() {
        val dir = Files.createTempDirectory("jarprep").toFile()
        val target = File(dir, "site.jar")
        val temp = File(dir, "site.jar.part")
        temp.writeText("fresh")
        JarFilePrep.replaceTarget(temp, target)
        assertEquals("fresh", target.readText())
        assertFalse(JarFilePrep.isWritable(target))
    }
}
