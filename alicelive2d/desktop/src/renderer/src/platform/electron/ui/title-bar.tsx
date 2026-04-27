import { useEffect, useState } from 'react';
import { Box, IconButton } from '@chakra-ui/react';
import {
  FiMinus, FiMaximize2, FiMinimize2, FiX, FiChevronsDown,
} from 'react-icons/fi';
import {
  lunariaColors,
} from '@/theme/lunaria-theme';

const titleBarIconButtonStyles = {
  bg: "transparent",
  color: lunariaColors.textMuted,
  border: "none",
  boxShadow: "none",
  minW: "20px",
  w: "20px",
  h: "20px",
  p: "0",
  borderRadius: "0",
  _hover: {
    bg: "transparent",
    color: lunariaColors.heading,
  },
  _active: {
    bg: "transparent",
    color: lunariaColors.heading,
  },
} as const;

function TitleBar(): JSX.Element {
  const [isMaximized, setIsMaximized] = useState(false);
  const [isFullScreen, setIsFullScreen] = useState(false);
  const isMac = window.electron?.process.platform === 'darwin';

  useEffect(() => {
    const handleMaximizeChange = (_event: any, maximized: boolean) => {
      setIsMaximized(maximized);
    };

    const handleFullScreenChange = (_event: any, fullScreen: boolean) => {
      setIsFullScreen(fullScreen);
    };

    window.electron?.ipcRenderer.on('window-maximized-change', handleMaximizeChange);
    window.electron?.ipcRenderer.on('window-fullscreen-change', handleFullScreenChange);

    return () => {
      window.electron?.ipcRenderer.removeAllListeners('window-maximized-change');
      window.electron?.ipcRenderer.removeAllListeners('window-fullscreen-change');
    };
  }, []);

  const handleMaximizeClick = () => {
    if (isFullScreen) {
      window.electron?.ipcRenderer.send('window-unfullscreen');
    } else {
      window.electron?.ipcRenderer.send('window-maximize');
    }
  };

  const getButtonLabel = () => {
    if (isFullScreen) return 'Exit Full Screen';
    if (isMaximized) return 'Restore';
    return 'Maximize';
  };

  const getButtonIcon = () => {
    if (isFullScreen) return <FiChevronsDown />;
    if (isMaximized) return <FiMinimize2 />;
    return <FiMaximize2 />;
  };

  if (isMac) {
    return (
      <Box
        position="absolute"
        top={0}
        left={0}
        width="100%"
        display="flex"
        alignItems="center"
        justifyContent="center"
        height="30px"
        background={lunariaColors.appBgSoft}
        borderBottom="1px solid"
        borderColor={lunariaColors.border}
        zIndex={1000}
        css={{
          '-webkit-app-region': 'drag',
          '-webkit-user-select': 'none',
        }}
      />
    );
  }

  return (
    <Box
      position="absolute"
      top={0}
      left={0}
      width="100%"
      display="flex"
      alignItems="center"
      justifyContent="flex-end"
      height="30px"
      background={lunariaColors.appBgSoft}
      borderBottom="1px solid"
      borderColor={lunariaColors.border}
      paddingX="8px"
      zIndex={1000}
      css={{ '-webkit-app-region': 'drag' }}
    >
      <Box display="flex" gap="1">
        <IconButton
          {...titleBarIconButtonStyles}
          size="xs"
          css={{ '-webkit-app-region': 'no-drag' }}
          onClick={() => window.electron?.ipcRenderer.send('window-minimize')}
          aria-label="Minimize"
        >
          <FiMinus />
        </IconButton>
        <IconButton
          {...titleBarIconButtonStyles}
          size="xs"
          css={{ '-webkit-app-region': 'no-drag' }}
          onClick={handleMaximizeClick}
          aria-label={getButtonLabel()}
        >
          {getButtonIcon()}
        </IconButton>
        <IconButton
          {...titleBarIconButtonStyles}
          size="xs"
          css={{ '-webkit-app-region': 'no-drag' }}
          _hover={{ bg: "transparent", color: '#a75f59' }}
          onClick={() => window.electron?.ipcRenderer.send('window-close')}
          aria-label="Close"
        >
          <FiX />
        </IconButton>
      </Box>
    </Box>
  );
}

export default TitleBar;
